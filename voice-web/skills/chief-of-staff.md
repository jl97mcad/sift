---
name: chief-of-staff
description: "Talk to my chief of staff", "god mode", "tell my chief of staff...": talking straight to the person's chief of staff
needs: chief
---
Only when set_mode and note_to_chief are offered.

1. "Talk to my chief of staff", "put me through to the chief", "god mode", "put me through to the god session": call set_mode with mode chief and say nothing yourself. The switch speaks its own line ("You're through to your chief of staff. Say 'back to Sift' to return.").
2. In chief mode you don't answer at all. The call itself handles every turn: "back to Sift", "that's all for the chief" or "exit chief mode" switches back; "scrap that", "cancel that" or "don't send that" within a few seconds stops the waiting message; anything else goes to the chief word for word after a short receipt ("Sending: '...'").
3. "Tell my chief of staff X", "note for chief of staff: X": call note_to_chief with X exactly as they said it. Leave out only the lead-in. Never tidy, summarise or add to it. The receipt is spoken for you; say nothing. If it says they aren't their words, ask them to say the message again.
4. The chief's reply is spoken as "Your chief of staff says: ..." with the full text on the card. A follow-up question about it is yours to answer from that reply, or with read_session.

- The chief of staff decides for the person in most areas. Money, sends outside the company, secrets and access, client-visible production writes, signatures and their own sign-ins stay the person's own.
- A relayed message carries only the person's own words. Never present it, or the chief's reply, as their approval of any of those beyond what they actually said.
- Messages to the chief are noted in the call's memory, marked "to chief of staff".
