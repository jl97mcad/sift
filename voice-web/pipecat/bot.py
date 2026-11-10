"""The voice call: Pipecat streams the person's speech in and the reply out, with real turn-taking.

The Sift page (served by server.mjs) opens a WebRTC call to this bot through server.mjs's /api/offer.
server.mjs stays the one owner of the tools, the prompt and background jobs: this bot fetches its
setup from the local side door (BOT_TOOLS, 127.0.0.1 only), calls tools there, and speaks job news
from its event feed into the open call.

Run: .venv/bin/python bot.py -t webrtc --host 127.0.0.1 --port 8774
Models (env): SIFT_LLM, SIFT_STT, SIFT_TTS, SIFT_TTS_VOICE, SIFT_TTS_RATE; key from OPENROUTER_KEY_FILE.
"""

import asyncio
import json
import os

import aiohttp
from loguru import logger

from pipecat.adapters.llm.schemas.function_schema import FunctionSchema
from pipecat.adapters.llm.schemas.tools_schema import ToolsSchema
from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.frames.frames import (
    BotStartedSpeakingFrame,
    BotStoppedSpeakingFrame,
    FunctionCallResultProperties,
    LLMFullResponseEndFrame,
    LLMFullResponseStartFrame,
    LLMMessagesAppendFrame,
    LLMRunFrame,
    TTSSpeakFrame,
    UserStartedSpeakingFrame,
    UserStoppedSpeakingFrame,
)
from pipecat.observers.base_observer import BaseObserver, FramePushed
from pipecat.observers.user_bot_latency_observer import UserBotLatencyObserver
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
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
}


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

    def __init__(self):
        super().__init__()
        self.user = self.bot = self.llm = False

    @property
    def quiet(self) -> bool:
        return not (self.user or self.bot or self.llm)

    async def on_push_frame(self, data: FramePushed):
        frame = data.frame
        if isinstance(frame, UserStartedSpeakingFrame):
            self.user = True
        elif isinstance(frame, UserStoppedSpeakingFrame):
            self.user = False
        elif isinstance(frame, BotStartedSpeakingFrame):
            self.bot = True
        elif isinstance(frame, BotStoppedSpeakingFrame):
            self.bot = False
        elif isinstance(frame, LLMFullResponseStartFrame):
            self.llm = True
        elif isinstance(frame, LLMFullResponseEndFrame):
            self.llm = False


async def bot(runner_args: RunnerArguments):
    assert isinstance(runner_args, SmallWebRTCRunnerArguments)
    http = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=90))
    async with http.get(f"{TOOLS}/bot/setup") as r:
        setup = await r.json()
    person = setup.get("person") or "the person"
    api_key = key()

    transport = SmallWebRTCTransport(
        webrtc_connection=runner_args.webrtc_connection,
        params=TransportParams(audio_in_enabled=True, audio_out_enabled=True),
    )
    stt = OpenAISTTService(api_key=api_key, base_url=OR, model=os.environ.get("SIFT_STT", "qwen/qwen3-asr-0.6b"))
    llm = OpenAILLMService(
        api_key=api_key,
        base_url=OR,
        settings=OpenAILLMService.Settings(
            model=os.environ.get("SIFT_LLM", "deepseek/deepseek-v4.1-flash"),
            max_tokens=800,
            # No hidden reasoning: it ate the budget after long lookups and left nothing to say.
            extra={"extra_body": {"reasoning": {"enabled": False}}},
        ),
    )
    # OpenRouter's fish-audio PCM comes back at 44.1 kHz, not OpenAI's 24 kHz.
    tts = OpenAITTSService(
        api_key=api_key,
        base_url=OR,
        model=os.environ.get("SIFT_TTS", "fish-audio/drama-3"),
        voice=os.environ.get("SIFT_TTS_VOICE", "alloy"),
        sample_rate=int(os.environ.get("SIFT_TTS_RATE", "44100")),
    )

    context = LLMContext([{"role": "system", "content": setup["prompt"]}], tools=schemas(setup["tools"]))
    pair = LLMContextAggregatorPair(context, user_params=LLMUserAggregatorParams(vad_analyzer=SileroVADAnalyzer()))
    pipeline = Pipeline([transport.input(), stt, pair.user(), llm, tts, transport.output(), pair.assistant()])

    busy = Busy()
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
        try:
            async with http.post(f"{TOOLS}/bot/tool/{name}", json=params.arguments or {}) as r:
                result = (await r.json()).get("result", "")
        except Exception as error:  # a failed tool is said, never silent
            result = f"That didn't work: {error}"
        logger.info(f"SIFT tool {name} {json.dumps(params.arguments)[:200]} -> {len(result)} chars")
        await params.result_callback(result)

    for tool in setup["tools"]:
        name = tool["function"]["name"]
        if name not in ("stay_quiet", "end_conversation"):
            llm.register_function(name, remote, cancel_on_interruption=name != "delegate")

    async def stay_quiet(params: FunctionCallParams):
        await params.result_callback("Staying quiet.", properties=FunctionCallResultProperties(run_llm=False))

    async def end_conversation(params: FunctionCallParams):
        await show({"type": "end"})  # the page hangs up once the goodbye has played
        await params.result_callback("Ended.", properties=FunctionCallResultProperties(run_llm=False))

    llm.register_function("stay_quiet", stay_quiet)
    llm.register_function("end_conversation", end_conversation)

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
            while not busy.quiet:
                await asyncio.sleep(0.4)
            if event.get("type") == "progress":
                await task.queue_frames([TTSSpeakFrame(event["text"])])
            elif event.get("type") == "finished":
                # Kept in the context, so "what did it find?" is answered from the real reply.
                note = (
                    f"(Not said by {person}. {event['to']} finished \"{event['task']}\" ({event['status']}) and replied: "
                    f"{event.get('reply') or '(nothing)'}) Tell {person} the result in one or two short spoken sentences, "
                    "starting with what it was about. If it needs their decision, ask that one question last."
                )
                await task.queue_frames([LLMMessagesAppendFrame(messages=[{"role": "user", "content": note}], run_llm=True)])
                await asyncio.sleep(1)  # let the turn start before the next item checks for quiet

    workers: list[asyncio.Task] = []

    @transport.event_handler("on_client_connected")
    async def _connected(_t, _c):
        logger.info("SIFT call connected")
        workers.extend([asyncio.create_task(follow()), asyncio.create_task(speak_news())])
        context.add_message({"role": "user", "content": f"(The call just connected. Greet {person} in a few words.)"})
        await task.queue_frames([LLMRunFrame()])

    @transport.event_handler("on_client_disconnected")
    async def _disconnected(_t, _c):
        logger.info("SIFT call ended")
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
