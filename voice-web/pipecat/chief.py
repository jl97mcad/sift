"""Chief-of-staff mode's pure parts: the phrases matched locally and the grace window.

No Pipecat here, so `python3 test_chief.py` checks it anywhere. bot.py uses it; server.mjs sends.
In chief mode the model never answers: each of the person's turns is an exit phrase (back to Sift),
a scrap phrase (inside the grace window, nothing is sent) or their words, queued verbatim.
"""

import re
import time

WINDOW = 4.0  # seconds after the person stops before a message goes; consecutive utterances join

# Said around a command without changing it: "okay, back to Sift please".
_LEAD = re.compile(
    r"^(?:(?:ok(?:ay)?|right|alright|all right|um+|uh+|er+|erm|so|well|oh|ah|yeah|yes|no|nope|wait|hang on|hold on|"
    r"actually|sorry|hey|sift|thanks|thank you|cheers|great|cool|perfect|lovely|good|fine|please|and)\b[\s,]*)+"
)
_TAIL = re.compile(r"(?:[\s,]+\b(?:please|thanks|thank you|cheers|now|then|mate|for now|for me|again))+$")

# Speech recognition hears "Sift" as many things.
_SIFT = r"(?:sift|shift|sith|sieve|sit|sips?|gift|swift|sifts|syft|normal|you|regular)"
_CHIEF = r"(?:(?:the|my|your) )?(?:chief(?: of staff)?|chief of stuff|chiefs?|god(?: session| mode)?|gods)"
EXIT = [re.compile(p) for p in (
    rf"(?:(?:go|take me|switch|put me|get me|come|bring me|send me|head|flip|i'm going|let's go|i want to go)(?: back)?(?: to)? )?back to {_SIFT}(?: mode)?",
    rf"(?:switch|go) to {_SIFT}(?: mode)?",
    rf"{_SIFT} mode",
    rf"(?:exit|leave|end|close|quit|stop|finish|drop|hang up on|hang up)(?: (?:the|this))? {_CHIEF}(?: mode| call| chat)?",
    rf"(?:exit|leave|end|quit|close)(?: (?:the|this))? (?:mode|call with (?:the |my )?chief(?: of staff)?)",
    rf"(?:that's|that is|that'll be|that will be) (?:all|it|everything)(?: (?:for|with) {_CHIEF})?",
    rf"(?:i'm|i am|we're|we are) (?:done|finished|through)(?: (?:with|talking to|for)(?: now)? {_CHIEF})?",
    rf"(?:done|finished) (?:with|talking to) {_CHIEF}",
    rf"(?:bye|goodbye|cheers|thanks|thank you) {_CHIEF}",
)]

# "Scrap" is heard as scrab, scrub, scrape, crap, crab...: any of them counts.
_SCRAPISH = r"(?:s ?[ck]r[aeiu]+[bp]+(?:ed|e)?|[ck]r[au]+[bp]+(?:ed)?|strap|scratch)"
_SCRAP_VERB = rf"(?:{_SCRAPISH}|cancel|delete|drop|bin|kill|ditch|forget|undo|strike|remove|lose|wipe|unsend)"
_SCRAP_WHAT = r"(?:that|it|this|those|them|the (?:last )?(?:one|message|note|bit)|that (?:last )?(?:one|message|note|bit)|what i (?:just )?said|everything)"
SCRAP = [re.compile(p) for p in (
    rf"{_SCRAP_VERB} {_SCRAP_WHAT}(?: (?:message|one|note|bit))?",
    rf"(?:{_SCRAPISH}|unsend)",  # alone; "Cancel." alone may be an answer to the chief
    rf"(?:don't|do not|dont|never) send (?:that|it|this|those|them|the (?:message|note)|that (?:message|note))(?: (?:message|one))?",
    rf"(?:don't|do not|dont) send",
    r"never ?mind(?: that)?",
    r"(?:no )?(?:i )?(?:take|taking) (?:that|it) back",
)]


def norm(text: str) -> str:
    """Lower case, curly quotes made straight, punctuation dropped, one space between words."""
    t = str(text or "").lower().replace("’", "'").replace("‘", "'")
    t = re.sub(r"[^a-z0-9' ]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()


def _core(text: str) -> str:
    t = norm(text)
    for _ in range(3):  # "okay, so, back to Sift, thanks"
        t = _TAIL.sub("", _LEAD.sub("", t)).strip()
    return t


def _matches(patterns, text: str) -> bool:
    whole, core = norm(text), _core(text)
    if len(whole.split()) > 12 or len(core.split()) > 9:  # a long sentence is a message, even if it says "back to Sift" in it
        return False
    return any(p.fullmatch(t) for p in patterns for t in {whole, core} if t)


def is_exit(text: str) -> bool:
    """'Back to Sift', 'that's all for the chief', 'exit chief mode', and forgiving variants."""
    return _matches(EXIT, text)


def is_scrap(text: str) -> bool:
    """'Scrap that', 'cancel that', 'don't send that', 'never mind'."""
    return _matches(SCRAP, text)


_FILLER = {"you", "thank", "thanks", "bye", "um", "uh", "hmm", "mm", "mhm", "okay", "ok"}


def clean_heard(text: str) -> str:
    """What speech recognition heard, minus what it invents from noise: other scripts in English-only
    audio ("嗯。"), stock phrases, and runs of filler. "" when nothing real is left (see speech.mjs isPhantom)."""
    t = re.sub(r"[^\u0000-\u024f\u2000-\u206f\u2018-\u201f]+", " ", str(text or ""))
    t = re.sub(r"\s+([.,!?])", r"\1", re.sub(r"\s+", " ", t)).strip()
    t = re.sub(r"(^|\s)[.,!?。]+(?=\s|$)", " ", t).strip()
    low = norm(t)
    if not low or re.search(r"thanks for watching|subtitles by|to be continued|like and subscribe|amara org", low):
        return ""
    words = low.split()
    if all(w in _FILLER for w in words) and (low in ("you", "thank you") or len(words) >= 3):
        return ""
    return t


def classify(text: str) -> str:
    """What one of the person's turns in chief mode is: exit, scrap or message ('' for nothing heard)."""
    if not norm(text):
        return ""
    if is_exit(text):
        return "exit"
    if is_scrap(text):
        return "scrap"
    return "message"


def split_tail(text: str) -> tuple[str, str]:
    """A turn that ends in a command said in the same breath: "Cancel the offsite. Scrap that." is
    ("Cancel the offsite.", "scrap"); "Tell him yes. Back to Sift." is ("Tell him yes.", "exit").
    Returns (text, "") when the last sentence isn't a command."""
    said = str(text or "").strip()
    for splitter in (r"(?<=[.!?])\s+", r"(?<=[,;])\s+"):  # sentences first, then "..., scrap that"
        parts = [p for p in re.split(splitter, said) if p.strip()]
        if len(parts) < 2:
            continue
        last = parts[-1]
        kind = "exit" if is_exit(last) else "scrap" if is_scrap(last) else ""
        if kind:
            return " ".join(parts[:-1]).strip().rstrip(",;"), kind
    return said, ""


def receipt(text: str, first: bool = True, words: int = 7) -> str:
    """The spoken receipt at the start of the grace window: the first few words, so a mishearing is caught."""
    said = re.sub(r"\s+", " ", str(text or "")).strip()
    parts = said.split(" ")
    quoted = said.rstrip(".!?, ") if len(parts) <= words + 1 else " ".join(parts[:words]).rstrip(".!?,;:") + "…"
    return f"{'Sending' if first else 'Adding'}: '{quoted}'"


def held(voice_at: float, turn_end: float, now: float, cap: float = 12.0) -> bool:
    """Speech heard on the line that no finished turn has caught up with yet (recognition and turn-taking
    run seconds behind the audio): a waiting message holds for it, so a late "scrap that" still counts.
    At most `cap` seconds after the last speech, so a noisy room can't hold a message forever."""
    return voice_at > turn_end and now - voice_at < cap


class Batch:
    """One message waiting out its grace window. Utterances join it; it goes once the person has been
    quiet for the whole window. The clock is passed in, so tests need no waiting."""

    def __init__(self, window: float = WINDOW):
        self.window = window
        self.parts: list[str] = []
        self.deadline: float | None = None
        self.via = ""  # "chief" (said in chief mode) or "note" (note_to_chief from normal mode)

    @property
    def pending(self) -> bool:
        return bool(self.parts)

    def add(self, text: str, now: float | None = None, via: str = "chief") -> bool:
        """Adds an utterance and restarts the window. True when it starts a new message."""
        text = str(text or "").strip()
        if not text:
            return False
        first = not self.parts
        if first:
            self.via = via
        self.parts.append(text)
        self.deadline = (time.monotonic() if now is None else now) + self.window
        return first

    def touch(self, now: float | None = None):
        """The person stopped speaking: the window starts again from now."""
        if self.parts:
            self.deadline = (time.monotonic() if now is None else now) + self.window

    def due(self, now: float | None = None, speaking: bool = False) -> bool:
        """Ready to send: something is waiting, the person isn't speaking and the window has passed."""
        now = time.monotonic() if now is None else now
        return bool(self.parts) and not speaking and self.deadline is not None and now >= self.deadline

    @property
    def text(self) -> str:
        return " ".join(self.parts)

    def peek(self) -> str:
        """The whole message, joined, without emptying the batch: a failed send keeps the words."""
        return self.text

    def take(self) -> str:
        """The whole message, joined, and the batch emptied."""
        text = self.text
        self.parts, self.deadline, self.via = [], None, ""
        return text

    def scrap(self) -> str:
        """Drops the waiting message; returns what was dropped."""
        return self.take()
