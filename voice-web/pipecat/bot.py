"""The voice call: Pipecat streams the person's speech in and the reply out, with real turn-taking.

The Sift page (served by server.mjs) opens a WebRTC call to this bot through server.mjs's /api/offer.
server.mjs stays the one owner of the tools, the prompt and background jobs: this bot fetches its
setup from the local side door (BOT_TOOLS, 127.0.0.1 only), calls tools there, and speaks job news
from its event feed into the open call.

Chief-of-staff mode (when the server's config has chief.worker): the person's turns skip the model and
go to their chief of staff word for word, after a short grace window; chief.py has the pure parts.

Run: .venv/bin/python bot.py -t webrtc --host 127.0.0.1 --port 8774
Models (env): SIFT_LLM, SIFT_STT, SIFT_TTS, SIFT_TTS_VOICE, SIFT_TTS_RATE; key from OPENROUTER_KEY_FILE.
"""

import asyncio
import json
import os
import random
import time
import uuid
from datetime import datetime, timezone

import aiohttp
import httpx
import numpy as np
from loguru import logger
from openai import DefaultAsyncHttpxClient

from pipecat.adapters.llm.schemas.function_schema import FunctionSchema
from pipecat.adapters.llm.schemas.tools_schema import ToolsSchema
from pipecat.audio.turn.smart_turn.base_smart_turn import SmartTurnParams
from pipecat.audio.turn.smart_turn.local_smart_turn_v3 import LocalSmartTurnAnalyzerV3
from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.turns.user_stop.turn_analyzer_user_turn_stop_strategy import TurnAnalyzerUserTurnStopStrategy
from pipecat.turns.user_turn_strategies import UserTurnStrategies
from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    FunctionCallResultProperties,
    InputAudioRawFrame,
    LLMFullResponseEndFrame,
    LLMContextFrame,
    LLMFullResponseStartFrame,
    LLMMessagesAppendFrame,
    LLMRunFrame,
    LLMTextFrame,
    TTSSpeakFrame,
    UserStartedSpeakingFrame,
    UserStoppedSpeakingFrame,
)
from pipecat.observers.base_observer import BaseObserver, FramePushed
from pipecat.observers.user_bot_latency_observer import UserBotLatencyObserver
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.frame_processor import FrameDirection, FrameProcessor
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.runner.types import RunnerArguments, SmallWebRTCRunnerArguments
from pipecat.services.llm_service import FunctionCallParams
from pipecat.services.openai.llm import OpenAILLMService
from pipecat.services.openai.stt import OpenAISTTService
from pipecat.services.openai.tts import OpenAITTSService
from pipecat.transports.base_transport import TransportParams
from pipecat.transports.smallwebrtc.transport import SmallWebRTCTransport

from chief import Batch, classify, clean_heard, held, receipt, split_tail

OR = "https://openrouter.ai/api/v1"
TOOLS = os.environ.get("BOT_TOOLS", "http://127.0.0.1:8773")
# What the page shows while a tool runs.
LABELS = {
    "sessions": "Checking sessions",
    "read_session": "Reading a session",
    "read_source": "Reading",
    "needs_queue": "Checking what needs you",
    "job_status": "Checking on the work",
    "delegate": "Handing it off",
    "paseo": "Running paseo",
    "skill": "Reading a how-to",
    "catch_up": "Catching up",
    "answer_ask": "Recording your answer",
    "recall": "Remembering",
    "plan": "Reading a plan",
    "plan_search": "Searching the plans",
    "github": "Checking GitHub",
    "vault": "Looking through your notes",
    "server_status": "Checking the server",
    "web": "Checking the web",
    "look_into": "Looking into it",
    "set_mode": "Switching mode",
    "note_to_chief": "Noting it for your chief of staff",
}
# Said the moment a tool starts when nothing has been said yet this turn, so a lookup never starts in silence.
FILLERS = ["Checking.", "One sec.", "Let me look.", "Just a moment.", "Looking now.", "Let me check."]
NO_FILLER = {"skill", "stay_quiet", "end_conversation", "set_mode", "note_to_chief"}
LOCAL = {"stay_quiet", "end_conversation", "set_mode", "note_to_chief"}  # answered here, not by the server


def key() -> str:
    if os.environ.get("OPENROUTER_API_KEY", "").strip():
        return os.environ["OPENROUTER_API_KEY"].strip()
    with open(os.environ.get("OPENROUTER_KEY_FILE", "/etc/sift-voice/openrouter-key")) as f:
        return f.read().strip()


def schemas(tools: list[dict]) -> ToolsSchema:
    """server.mjs's OpenAI-style tool list, as Pipecat schemas."""
    out = []
    for tool in tools:
        fn = tool["function"]
        params = fn.get("parameters") or {}
        out.append(
            FunctionSchema(
                name=fn["name"],
                description=fn.get("description", ""),
                properties=params.get("properties") or {},
                required=params.get("required") or [],
            )
        )
    return ToolsSchema(standard_tools=out)


class Busy(BaseObserver):
    """Who is talking or thinking, so news waits for a quiet moment instead of talking over anyone."""

    def __init__(self, turn=None, batch=None, stale_after: float = 12.0):
        super().__init__()
        self.user = self.bot = self.llm = False
        self.turn = turn
        self.batch = batch  # a chief message's grace window starts again whenever they stop speaking
        self.turn_end = 0.0  # when the last turn of theirs ended (monotonic)
        self.last = 0.0  # last frame that should have cleared a flag; a stall must not silence news
        self.stale_after = stale_after

    @property
    def quiet(self) -> bool:
        # A TTS or LLM error can eat the matching end frame, leaving a flag set for the rest of the
        # call and muting every news item. Flags older than stale_after count as cleared.
        stale = self.last and time.monotonic() - self.last > self.stale_after
        return stale or not (self.user or self.bot or self.llm)

    async def on_push_frame(self, data: FramePushed):
        frame = data.frame
        if isinstance(frame, (BotStartedSpeakingFrame, BotStoppedSpeakingFrame, LLMFullResponseStartFrame,
                              LLMFullResponseEndFrame, UserStartedSpeakingFrame, UserStoppedSpeakingFrame)):
            self.last = time.monotonic()
        if isinstance(frame, UserStartedSpeakingFrame):
            self.user = True
            if self.turn:
                self.turn.reset()
        elif isinstance(frame, UserStoppedSpeakingFrame):
            self.user = False
            if self.turn:
                self.turn.reset()
            self.turn_end = time.monotonic()
            if self.batch:
                self.batch.touch()
        elif isinstance(frame, BotStartedSpeakingFrame):
            self.bot = True
        elif isinstance(frame, BotStoppedSpeakingFrame):
            self.bot = False
        elif isinstance(frame, LLMFullResponseStartFrame):
            self.llm = True
        elif isinstance(frame, LLMFullResponseEndFrame):
            self.llm = False


class Turn(FrameProcessor):
    """Sits between the model and the voice: knows whether anything has been said this turn."""

    def __init__(self):
        super().__init__()
        self.spoke = self.filled = False
        self.last = ""

    def reset(self):
        self.spoke = self.filled = False

    async def process_frame(self, frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, LLMTextFrame) and frame.text.strip():
            self.spoke = True
        await self.push_frame(frame, direction)

    def filler(self) -> str | None:
        """A short line to say now, at most once a turn and only before anything else is said."""
        if self.spoke or self.filled:
            return None
        self.filled = True
        line = random.choice([f for f in FILLERS if f != self.last])
        self.last = line
        return line


class Ear(FrameProcessor):
    """First in the line: hears the person start talking before speech recognition and turn-taking catch
    up (they run seconds behind the audio), so a waiting chief message never goes while they're still
    saying "scrap that". Only listens while a message is waiting."""

    THRESHOLD = 900.0  # RMS on the int16 scale: speech, not room noise
    RUN = 0.25  # seconds of loud audio that count as speech, not a click

    def __init__(self, armed):
        super().__init__()
        self.armed = armed  # () -> bool: a chief message is waiting
        self.voice_at = 0.0
        self._loud_since: float | None = None

    async def process_frame(self, frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, InputAudioRawFrame) and self.armed():
            samples = np.frombuffer(frame.audio, dtype=np.int16).astype(np.float32)
            now = time.monotonic()
            if samples.size and float(np.sqrt(np.mean(samples * samples))) >= self.THRESHOLD:
                self._loud_since = self._loud_since or now
                if now - self._loud_since >= self.RUN:
                    self.voice_at = now
            else:
                self._loud_since = None
        await self.push_frame(frame, direction)


class Gate(FrameProcessor):
    """Between the person's turn and the model. Each turn's new words pass through `handle` first; when
    it takes them (chief mode, or "scrap that" while a note waits), the model never runs for that turn.
    In chief mode nothing reaches the model at all, so no answer of its own is ever spoken."""

    def __init__(self, closed, handle):
        super().__init__()
        self.closed = closed  # () -> bool: chief mode is on
        self.handle = handle  # async (list of (index, text)) -> bool: True when the turn was taken
        self.seen = 0  # context messages already looked at

    def forget(self, context: LLMContext, indexes: list[int]):
        """Takes the person's raw words for chief-mode turns out of the context; notes of what was sent go in instead."""
        if not indexes:
            return
        drop = set(indexes)
        messages = [m for i, m in enumerate(context.get_messages()) if i not in drop]
        context.set_messages(messages)
        self.seen = len(messages)

    async def process_frame(self, frame, direction: FrameDirection):
        await super().process_frame(frame, direction)
        if isinstance(frame, LLMContextFrame) and direction == FrameDirection.DOWNSTREAM:
            if getattr(frame, "speculation", False):  # a provisional copy, before the turn has ended
                if self.closed():
                    return
                await self.push_frame(frame, direction)
                return
            messages = frame.context.get_messages()
            if self.seen > len(messages):
                self.seen = 0
            new = [
                (i, m["content"])
                for i, m in enumerate(messages)
                if i >= self.seen and m.get("role") == "user" and isinstance(m.get("content"), str) and not m["content"].startswith("(")
            ]
            self.seen = len(messages)
            if await self.handle(new) or self.closed():
                logger.info("SIFT chief mode: turn handled without the model")
                return
        await self.push_frame(frame, direction)


async def bot(runner_args: RunnerArguments):
    assert isinstance(runner_args, SmallWebRTCRunnerArguments)
    http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=90))
    async with http.get(f"{TOOLS}/bot/setup") as r:
        setup = await r.json()
    person = setup.get("person") or "the person"

    async def read_ahead() -> str:
        """The needs queue, sessions and preload sources, read while the call connects."""
        try:
            async with http.get(f"{TOOLS}/bot/context", timeout=aiohttp.ClientTimeout(total=8)) as r:
                return (await r.json()).get("context", "")
        except Exception as error:
            logger.warning(f"SIFT preload failed: {error}")
            return ""

    ahead = asyncio.create_task(read_ahead())  # "" unless the server's config turns preload on
    api_key = key()

    transport = SmallWebRTCTransport(
        webrtc_connection=runner_args.webrtc_connection,
        params=TransportParams(audio_in_enabled=True, audio_out_enabled=True),
    )
    # Every provider call is bounded: the SDK defaults are 600 s with two retries, which leaves a call
    # deaf for half an hour when OpenRouter stalls. One shared client, 20 s total and 5 s to connect.
    timeout = httpx.Timeout(float(os.environ.get("SIFT_PROVIDER_TIMEOUT", "20")), connect=5.0)
    provider_http = DefaultAsyncHttpxClient(timeout=timeout)
    model = os.environ.get("SIFT_LLM", "deepseek/deepseek-v4.1-flash")
    fallback = os.environ.get("SIFT_LLM_FALLBACK", "deepseek/deepseek-v4-flash")
    stt = OpenAISTTService(api_key=api_key, base_url=OR, model=os.environ.get("SIFT_STT", "qwen/qwen3-asr-0.6b"),
                           http_client=provider_http)
    llm = OpenAILLMService(
        api_key=api_key,
        base_url=OR,
        settings=OpenAILLMService.Settings(
            model=model,
            max_tokens=800,
            # No hidden reasoning: it ate the budget after long lookups and left nothing to say.
            extra={"extra_body": {
                "reasoning": {"enabled": False},
                # A provider stall costs one turn, not the call: OpenRouter tries the next model in the
                # list, and asks for the fastest provider it has.
                "models": [model] + ([fallback] if fallback and fallback != model else []),
                "provider": {"sort": "throughput"},
            }},
        ),
        # No first token within 3 s: re-issue once instead of leaving the person in silence.
        retry_timeout_secs=float(os.environ.get("SIFT_LLM_RETRY_S", "3")),
        retry_on_timeout=True,
        http_client=provider_http,
    )
    # 24 kHz is what OpenAI-compatible TTS returns (and what the service asks for); 44.1 kHz only
    # gave a sample-rate warning and an extra resample.
    tts = OpenAITTSService(
        api_key=api_key,
        base_url=OR,
        model=os.environ.get("SIFT_TTS", "fish-audio/drama-3"),
        voice=os.environ.get("SIFT_TTS_VOICE", "alloy"),
        sample_rate=int(os.environ.get("SIFT_TTS_RATE", "24000")),
        http_client=provider_http,
    )

    context = LLMContext([{"role": "system", "content": setup["prompt"]}], tools=schemas(setup["tools"]))
    # Smart Turn's default "incomplete" fallback is 3 s: on finished sentences that read as unfinished
    # it added about 2.8 s a turn (25 of 196 on 10-11 Nov). 0.8 s keeps the judgement, drops the wait.
    turn_analyzer = LocalSmartTurnAnalyzerV3(params=SmartTurnParams(stop_secs=float(os.environ.get("SIFT_TURN_STOP_S", "0.8"))))
    pair = LLMContextAggregatorPair(context, user_params=LLMUserAggregatorParams(
        vad_analyzer=SileroVADAnalyzer(),
        user_turn_stop_timeout=float(os.environ.get("SIFT_TURN_TIMEOUT_S", "1.5")),
        user_turn_strategies=UserTurnStrategies(stop=[TurnAnalyzerUserTurnStopStrategy(turn_analyzer=turn_analyzer)]),
    ))
    turn = Turn()
    chief = setup.get("chief")  # None unless the server's config has chief.worker
    mode = "sift"
    batch = Batch()

    async def chief_turn(new: list) -> bool:  # defined below; the gate needs it now
        return await handle_chief_turn(new)

    gate = Gate(lambda: mode == "chief", chief_turn)
    ear = Ear(lambda: batch.pending)
    pipeline = Pipeline([transport.input(), ear, stt, pair.user(), gate, llm, turn, tts, transport.output(), pair.assistant()])

    busy = Busy(turn, batch)
    latency = UserBotLatencyObserver()

    @latency.event_handler("on_latency_measured")
    async def _measured(_obs, seconds):
        logger.info(f"SIFT latency end-of-speech->bot-audio {seconds:.3f}s")

    task = PipelineTask(
        pipeline,
        params=PipelineParams(enable_metrics=True, enable_usage_metrics=True),
        observers=[latency, busy],
    )
    rtvi = task.rtvi

    async def show(data: dict):
        await rtvi.send_server_message(data)

    # ---- Tools: each one is a call to server.mjs, which owns them.
    async def remote(params: FunctionCallParams):
        name = params.function_name
        await show({"type": "tool", "name": name, "label": LABELS.get(name, name), "args": params.arguments})
        line = turn.filler() if setup.get("filler") and name not in NO_FILLER else None
        if line:
            # Spoken only: kept out of the context, so the tool call and its result stay side by side.
            await params.llm.push_frame(TTSSpeakFrame(line, append_to_context=False), FrameDirection.DOWNSTREAM)
            logger.info(f"SIFT filler {line!r} before {name}")
        args = dict(params.arguments or {})
        if name == "answer_ask":
            # What the person actually said, so the server can check the answer is their words.
            said = [m["content"] for m in context.get_messages() if m.get("role") == "user" and isinstance(m.get("content"), str)
                    and not m["content"].startswith("(")]
            args["_heard"] = " ".join(said[-3:])
            args["_last"] = said[-1] if said else ""
            args["_turn"] = len(said)  # a yes must come in a later turn than its read-back
            args["_call"] = call_id
        try:
            async with http.post(f"{TOOLS}/bot/tool/{name}", json=args) as r:
                result = (await r.json()).get("result", "")
        except Exception as error:  # a failed tool is said, never silent
            result = f"That didn't work: {error}"
        result = str(result)
        if len(result) > 6000:  # a long read must not crowd the context (cost, latency, provider 400s)
            result = result[:6000] + "…"
        logger.info(f"SIFT tool {name} {json.dumps(params.arguments)[:200]} -> {len(result)} chars")
        await params.result_callback(result)

    for tool in setup["tools"]:
        name = tool["function"]["name"]
        if name not in LOCAL:
            llm.register_function(name, remote, cancel_on_interruption=name not in ("delegate", "look_into"))

    async def stay_quiet(params: FunctionCallParams):
        await params.result_callback("Staying quiet.", properties=FunctionCallResultProperties(run_llm=False))

    async def end_conversation(params: FunctionCallParams):
        await show({"type": "end"})  # the page hangs up once the goodbye has played
        await params.result_callback("Ended.", properties=FunctionCallResultProperties(run_llm=False))

    llm.register_function("stay_quiet", stay_quiet)
    llm.register_function("end_conversation", end_conversation)

    # ---- Chief-of-staff mode: the person's words go to their chief of staff verbatim; the model stays out.
    label = (chief or {}).get("label") or "Chief of staff"
    deferred: list[dict] = []  # other news waits until they're back with Sift

    async def say(text: str, frame_source=None):
        """A fixed line, spoken without the model and kept out of the context."""
        frame = TTSSpeakFrame(text, append_to_context=False)
        if frame_source is not None:
            await frame_source.push_frame(frame, FrameDirection.DOWNSTREAM)
        else:
            await task.queue_frames([frame])

    async def enter(source=None):
        nonlocal mode
        mode = "chief"  # set_mode's own result tells the model; nothing is added mid-call
        await show({"type": "mode", "mode": "chief", "label": label})
        line = "You're through to your chief of staff. Say 'back to Sift' to return."
        if chief and chief.get("dryRun"):
            line += " This is a test: nothing is sent."
        await say(line, source)
        logger.info("SIFT chief mode on")

    async def leave(source=None):
        nonlocal mode
        mode = "sift"
        if source is None:  # left by saying so, not through set_mode: the model must know it's back
            context.add_message({"role": "assistant", "content": f"(Chief-of-staff mode off: {person} is talking to me again. A note for the chief now needs note_to_chief; I never say I've passed something on unless note_to_chief took it.)"})
        await show({"type": "mode", "mode": "sift", "label": ""})
        waiting = f" {receipt(batch.text)}, unless you say scrap that." if batch.pending else ""
        await say("Back to Sift." + waiting, source)
        logger.info("SIFT chief mode off")
        for event in deferred:
            news.put_nowait(event)
        deferred.clear()

    async def handle_chief_turn(new: list) -> bool:
        """The person's new words this turn, before the model. True when they were dealt with here."""
        if not chief:
            return False
        if mode != "chief":
            # A note from normal mode is waiting out its window: only "scrap that" is taken here.
            if batch.pending and len(new) == 1 and classify(new[0][1]) == "scrap":
                await scrap()
                return True
            return False
        if not new:
            return True  # an empty turn in chief mode: nothing to send, nothing to say
        gate.forget(context, [i for i, _ in new])
        for _, heard in new:
            text = clean_heard(heard)
            if not text:
                logger.info("SIFT chief mode: nothing real heard (noise), nothing queued")
                continue
            kind = classify(text)
            tail = ""
            if kind == "message":
                text, tail = split_tail(text)  # "Cancel the offsite. Scrap that." in one breath
                head = classify(text)
                if tail and head in ("exit", "scrap"):  # two commands at once: "back to Sift, scrap that"
                    if "scrap" in (head, tail):
                        await scrap()
                    if "exit" in (head, tail):
                        await leave()
                        return True
                    continue
                if tail == "scrap":
                    batch.add(text, via="chief")
                    await scrap()
                    continue
                first = batch.add(text, via="chief")
                if tail != "exit":
                    await say(receipt(text, first))
                await show({"type": "chief", "state": "waiting", "text": batch.text})
                logger.info(f"SIFT chief message waiting ({len(batch.text)} chars, {'new' if first else 'joined'})")
            if kind == "exit" or tail == "exit":
                await leave()
                return True
            if kind == "scrap":
                await scrap()
        return True

    async def scrap():
        if batch.pending:
            dropped = batch.scrap()
            context.add_message({"role": "assistant", "content": f"(Scrapped, not sent to chief of staff) {dropped}"})
            await show({"type": "chief", "state": "scrapped", "text": dropped})
            await say("Scrapped.")
            logger.info("SIFT chief message scrapped")
        else:
            await say("Nothing's waiting to send; the last one already went. Say it another way if it was for your chief of staff.")

    async def send_chief(text: str, via: str) -> bool:
        """Sends one message. True when the server took it; the caller only then drops it from the batch."""
        try:
            async with http.post(f"{TOOLS}/bot/chief/send", json={"text": text, "via": via, "call": call_id}) as r:
                sent = await r.json()
        except Exception as error:
            sent = {"ok": False, "result": f"That didn't send: {error}"}
        if sent.get("ok"):
            context.add_message({"role": "assistant", "content": f"(Sent to chief of staff) {text}"})
            await show({"type": "chief", "state": "sent", "text": text, "dryRun": bool(sent.get("dryRun"))})
            logger.info(f"SIFT chief message sent ({len(text)} chars{', dry run' if sent.get('dryRun') else ''})")
            return True
        await show({"type": "chief", "state": "failed", "text": text})
        await say(f"That didn't reach your chief of staff. {sent.get('result', '')}".strip())
        logger.warning(f"SIFT chief send failed: {sent.get('result')}")
        return False

    async def chief_ticker():
        """Sends a waiting message once the person has been quiet for its whole window."""
        failures = 0
        while True:
            await asyncio.sleep(0.25)
            if batch.due(speaking=busy.user or held(ear.voice_at, busy.turn_end, time.monotonic())):
                via = batch.via
                text = batch.peek()
                # Take only after the server has it: a failed send keeps their words and retries.
                if await send_chief(text, via):
                    batch.take()
                    failures = 0
                else:
                    failures += 1
                    if failures < 3:  # retry in 10 s; after three, keep the words for the hangup send
                        batch.deadline = time.monotonic() + 10
                    else:
                        batch.deadline = None

    async def set_mode(params: FunctionCallParams):
        want = str((params.arguments or {}).get("mode", "")).lower()
        if not chief:
            await params.result_callback("Chief-of-staff mode isn't set up here.")
            return
        if want == "chief":
            await enter(params.llm)
            result = "Chief-of-staff mode is on; the switch said its line. Say nothing."
        else:
            if mode == "chief":
                await leave(params.llm)
            result = "Back in normal mode; the switch said its line. Say nothing."
        await params.result_callback(result, properties=FunctionCallResultProperties(run_llm=False))

    async def note_to_chief(params: FunctionCallParams):
        text = str((params.arguments or {}).get("text", "")).strip()
        said = [m["content"] for m in context.get_messages() if m.get("role") == "user" and isinstance(m.get("content"), str)
                and not m["content"].startswith("(")]
        try:
            async with http.post(f"{TOOLS}/bot/chief/check", json={"text": text, "_heard": " ".join(said[-3:])}) as r:
                check = await r.json()
        except Exception as error:
            check = {"ok": False, "result": f"That didn't work: {error}"}
        if not check.get("ok"):
            logger.info("SIFT note_to_chief refused: not their words")
            await params.result_callback(check.get("result", "Not sent."))
            return
        first = batch.add(text, via="note")
        await say(receipt(text, first), params.llm)
        await show({"type": "chief", "state": "waiting", "text": batch.text})
        logger.info(f"SIFT note_to_chief waiting ({len(batch.text)} chars)")
        await params.result_callback(
            "Waiting a few seconds, then it goes to their chief of staff verbatim; the receipt was spoken. Say nothing.",
            properties=FunctionCallResultProperties(run_llm=False),
        )

    if chief:
        llm.register_function("set_mode", set_mode)
        llm.register_function("note_to_chief", note_to_chief)

    # A tap on the orb while it talks: stop and listen.
    @rtvi.event_handler("on_client_message")
    async def _client_message(_rtvi, message):
        if getattr(message, "type", None) == "interrupt":
            await rtvi.interrupt_bot()

    # ---- News from background work, spoken in a quiet moment.
    news: asyncio.Queue = asyncio.Queue()

    async def follow():
        while True:
            try:
                async with http.get(f"{TOOLS}/bot/events", timeout=aiohttp.ClientTimeout(total=None, sock_read=60)) as r:
                    async for raw in r.content:
                        line = raw.decode().strip()
                        if line.startswith("data: "):
                            await news.put(json.loads(line[6:]))
            except asyncio.CancelledError:
                raise
            except Exception as error:
                logger.warning(f"SIFT news feed dropped: {error}")
                await asyncio.sleep(2)

    async def speak_news():
        while True:
            event = await news.get()
            try:
                await speak_event(event)
            except asyncio.CancelledError:
                raise
            except Exception as error:  # one bad event must not kill the feed for the rest of the call
                logger.error(f"SIFT news event failed: {error}")

    async def speak_event(event: dict):
        while not busy.quiet:
            await asyncio.sleep(0.4)
        if event.get("type") == "chief_reply":
            # The full reply goes in the context and on the page; the short version is spoken.
            context.add_message({"role": "user", "content": f"(Not said by {person}. Their chief of staff replied: {(event.get('reply') or '(nothing)')[:2500]})"})
            context.add_message({"role": "assistant", "content": event["line"]})
            await show({"type": "chief", "state": "reply", "text": event.get("reply", ""), "line": event["line"]})
            await say(event["line"])
            logger.info(f"SIFT chief reply spoken ({len(event['line'])} chars)")
            await asyncio.sleep(1)
            return
        if mode == "chief":
            # Other news would make the model talk: it waits until they're back with Sift. Progress is dropped.
            if event.get("type") == "finished":
                deferred.append(event)
            return
        if event.get("type") == "progress":
            await task.queue_frames([TTSSpeakFrame(event["text"])])
        elif event.get("type") == "finished":
            # Kept in the context, so "what did it find?" is answered from the real reply.
            note = (
                f"(Not said by {person}. {event['to']} finished \"{event['task']}\" ({event['status']}) and replied: "
                f"{event.get('reply') or '(nothing)'}) Tell {person} the result in one or two short spoken sentences, "
                "starting with what it was about. If it needs their decision, ask that one question last."
            )
            turn.reset()
            await task.queue_frames([LLMMessagesAppendFrame(messages=[{"role": "user", "content": note}], run_llm=True)])
            await asyncio.sleep(1)  # let the turn start before the next item checks for quiet

    workers: list[asyncio.Task] = []
    started = datetime.now(timezone.utc)
    call_id = uuid.uuid4().hex  # ties this call's answered asks to its note

    preloaded = connected_once = False

    def add_preload(block: str):
        """Adds the already-read block once, as its own message.

        It used to be appended to the system message, which changed that message on every call and
        so broke the provider's prompt cache for the largest part of the prompt. As a message, the
        system prefix stays identical and the block is paid for once.
        """
        nonlocal preloaded
        if not block or preloaded:
            return
        preloaded = True
        context.add_message({"role": "user", "content": f"(Already read for this call, not said by {person}:\n{block})"})
        logger.info(f"SIFT preload added, {len(block)} chars")

    @transport.event_handler("on_client_connected")
    async def _connected(_t, _c):
        nonlocal started, connected_once
        if not connected_once:  # a reconnect keeps the call's first start time
            connected_once = True
            started = datetime.now(timezone.utc)
            # One set of workers per call, not per connection: a reconnect used to start a second
            # news feed and a second chief ticker, so delivery could double or race.
            workers.extend([asyncio.create_task(follow()), asyncio.create_task(speak_news())])
            if chief:
                workers.append(asyncio.create_task(chief_ticker()))
        logger.info("SIFT call connected")
        # Greet at once; the read-ahead lands in the system message when it's ready. Waiting for it
        # (up to 2.5 s) delayed the first words of every call.
        context.add_message({"role": "user", "content": f"(The call just connected. Greet {person} in a few words.)"})
        await task.queue_frames([LLMRunFrame()])
        try:
            add_preload(await asyncio.wait_for(asyncio.shield(ahead), timeout=2.5))
        except asyncio.TimeoutError:
            ahead.add_done_callback(lambda t: add_preload(t.result()) if not t.cancelled() and not t.exception() else None)

    def transcript() -> list[dict]:
        """The person's words and the assistant's, for the server's note of the call."""
        out = []
        for m in context.get_messages():
            if m.get("role") in ("user", "assistant") and isinstance(m.get("content"), str) and m["content"].strip():
                out.append({"role": m["role"], "text": m["content"]})
        return out

    @transport.event_handler("on_client_disconnected")
    async def _disconnected(_t, _c):
        logger.info("SIFT call ended")
        if batch.pending:  # they hung up inside the window without scrapping it: it goes
            via = batch.via
            if await send_chief(batch.peek(), via):
                batch.take()
            else:
                logger.error(f"SIFT chief message not sent before hangup ({len(batch.peek())} chars)")
        try:
            body = {"started": started.isoformat(), "ended": datetime.now(timezone.utc).isoformat(), "call": call_id, "turns": transcript()}
            async with http.post(f"{TOOLS}/bot/call-ended", json=body, timeout=aiohttp.ClientTimeout(total=5)) as r:
                await r.read()
        except Exception as error:
            logger.warning(f"SIFT call note not sent: {error}")
        await task.cancel()

    try:
        await PipelineRunner(handle_sigint=runner_args.handle_sigint).run(task)
    finally:
        for w in workers:
            w.cancel()
        await http.close()


if __name__ == "__main__":
    from pipecat.runner.run import main

    main()
