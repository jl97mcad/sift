"""Checks for chief.py, the pure parts of chief-of-staff mode. Run: python3 test_chief.py (check.mjs runs it too)."""

from chief import Batch, classify, is_exit, is_scrap, receipt

# Leaving the mode: the phrases in the brief, and how speech recognition tends to hear them.
for said in [
    "Back to Sift.", "back to sift please", "Okay, back to Sift.", "Go back to Sift", "Take me back to Sift, thanks.",
    "Back to shift.", "back to normal", "Sift mode", "That's all for the chief.", "That's all for my chief of staff.",
    "that's all", "Exit chief mode.", "Exit chief of staff mode", "Leave the chief of staff.", "End chief mode",
    "I'm done with the chief of staff", "Done with the chief.", "Bye chief.", "Thanks, that's all for the chief, thanks.",
    "Exit god mode", "Leave god mode.",
]:
    assert is_exit(said), said
    assert classify(said) == "exit", said

# Not an exit: real messages, even ones that mention Sift or the chief.
for said in [
    "Tell the team we're going back to Sift for the voice work next week.",
    "Yes.", "No, hold the Mattel invoice until Friday.", "What's the chief of staff's view on the hiring plan?",
    "Book the call for Thursday", "Back to the Mattel question, go with option B.",
]:
    assert not is_exit(said), said
    assert classify(said) == "message", said

# Scrapping the waiting message.
for said in ["Scrap that.", "scrap that", "Cancel that.", "Don't send that.", "No, don't send that!", "Wait, scrap that.",
             "Scrap.", "Never mind.", "Actually, cancel that message.", "Delete that", "Don't send it", "Scratch that."]:
    assert is_scrap(said), said
    assert classify(said) == "scrap", said
for said in ["Cancel.", "Delete.", "Cancel the Thursday meeting with the design team.", "Don't send the invoice to the client yet.", "Scrap the old plan and go with B."]:
    assert not is_scrap(said), said
    assert classify(said) == "message", said
assert classify("") == "" and classify("  ...  ") == ""

# A command said in the same breath as a message (one turn): the message, then the command.
from chief import split_tail
assert split_tail("Cancel the site booking for next month. Scrub that.") == ("Cancel the site booking for next month.", "scrap")
assert split_tail("Tell him yes. Back to Sift.") == ("Tell him yes.", "exit")
assert split_tail("Book it for Friday. Then tell Will.") == ("Book it for Friday. Then tell Will.", "")
assert split_tail("Scrap that.") == ("Scrap that.", "")  # a whole-turn command is classify's job
assert classify("Scrub that.") == "scrap"
for heard in ["Scrab that.", "Scrape that.", "Scrapped that.", "Crap that.", "Crab that.", "Skrap that.", "Scrub it."]:  # how recognition hears it
    assert classify(heard) == "scrap", heard
for said in ["Ship that.", "Wrap that up for Friday.", "Grab that file for me."]:
    assert classify(said) == "message", said
assert split_tail("Cancel the offsite, scrap that.") == ("Cancel the offsite", "scrap")
assert split_tail("Back to Sift, scrap that.") == ("Back to Sift", "scrap") and classify("Back to Sift") == "exit"
assert split_tail("Book Rome, Paris and Lyon.") == ("Book Rome, Paris and Lyon.", "")

# The spoken receipt: the first few words, so a mishearing is caught in time.
assert receipt("Move the board meeting to Friday.") == "Sending: 'Move the board meeting to Friday'"
assert receipt("Tell Will the Mattel deck needs the new numbers before the call tomorrow") == "Sending: 'Tell Will the Mattel deck needs the…'"
assert receipt("and the budget too", first=False) == "Adding: 'and the budget too'"

# The grace window: utterances join, the clock restarts each time, nothing goes while the person talks.
b = Batch(window=4.0)
assert not b.pending and not b.due(now=100)
assert b.add("Move the board meeting", now=0) is True
assert b.add("to Friday afternoon", now=2) is False  # joins the same message
assert not b.due(now=5.9)
assert b.due(now=6.0)
assert not b.due(now=6.0, speaking=True)  # never while the person is talking
b.touch(now=7)  # they stopped speaking again: a fresh window
assert not b.due(now=10.9) and b.due(now=11)
assert b.text == "Move the board meeting to Friday afternoon"
assert b.take() == "Move the board meeting to Friday afternoon" and not b.pending
b.add("Hold the invoice", now=20, via="note")
assert b.via == "note"
assert b.scrap() == "Hold the invoice" and not b.pending and not b.due(now=99)
b.touch(now=30)  # touching an empty batch starts nothing
assert not b.due(now=99)
assert b.add("  ", now=0) is False and not b.pending

# What recognition invents from noise never goes to the chief.
from chief import clean_heard
assert clean_heard("Hold the larkspur invoice until Friday. 嗯。") == "Hold the larkspur invoice until Friday."
assert clean_heard("嗯。") == "" and clean_heard("Thank you.") == "" and clean_heard("you") == "" and clean_heard("Thanks for watching!") == ""
assert clean_heard("Yes.") == "Yes." and clean_heard("No.") == "No." and clean_heard("Okay.") == "Okay."
assert clean_heard("Book it for café Rouge.") == "Book it for café Rouge."

# Holding for speech the turn-taking hasn't caught up with yet.
from chief import held
assert held(voice_at=10.0, turn_end=8.0, now=12.0)  # spoke at 10, no turn has ended since: hold
assert not held(voice_at=10.0, turn_end=11.0, now=12.0)  # that speech became a turn: go
assert not held(voice_at=10.0, turn_end=8.0, now=22.5)  # never longer than the cap
assert not held(voice_at=0.0, turn_end=0.0, now=5.0)

print("chief ok")
