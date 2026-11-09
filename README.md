# Sift

A small floating agent and Lark companion for macOS. A green head rests at
the right edge of the screen; click it for a compact panel with your coding
agents running in [Paseo](https://paseo.sh) (Control, Finance, whatever you
seat), then your unread and pinned Lark chats.

Sift is a standalone app on Lark's public Open API. It does not patch, read or
automate the Lark desktop client.

![Sift inbox](docs/screenshots/inbox.png) ![Sift Control](docs/screenshots/control.png)

## Features

- **Edge head.** Rests at the right screen edge; ⌥Space or a click opens the
  panel. Drag the panel's header to move it; drop it against the right edge to
  dock it again. Reduce Motion stops every animation.
- **Inbox and All chats.** Unread activity first, with previews, mute and
  mark-read. All chats pages through your full chat list.
- **Pinned chats.** Up to ten in the rail (⌘1–9). Drag to reorder.
- **Conversations.** Text, rich posts with links, mentions and images, card
  text, images (open, save, copy), files, voice and video (saved through the
  authenticated Lark resource API), shared chats and contacts, forwarded
  bundles and system events. Replies quote their parent; edits, recalls,
  threads and bots are marked. Messages from one sender in the same minute
  group together.
- **Agent seats (optional).** Any number of Paseo agent sessions, first in
  the rail, each with its own face in its own colour and name. Talk to each
  from the panel: readable replies with Markdown, named speakers, a live
  activity row, the work between replies (commands, edits, checklists,
  failures) folded into one line that opens to each step, visible errors and
  notifications, and names of Lark people and groups linked to their chats.
  An agent that hands off to a new session of itself stays on its seat.
- **Needs you.** The head and that agent's face pulse for an open ask from
  its runner or a Paseo request (permission, plan, question), until you have
  seen it. Each request shows what it asks and opens in Paseo to answer.
- **Notifications (opt-in).** Optional macOS banners and sound, never while
  the panel is focused.

## Requirements

- macOS 14 or later, with the Xcode Command Line Tools (Swift 5.9+) to build.
- A Lark account and a self-built Lark app in your tenant (see Setup).
- Optional, for the Control seat: the Paseo desktop app (0.14) on the Mac and a
  reachable Paseo daemon that runs your Control agent.
- Optional, for open asks: a Control runner whose Paseo daemon runs the
  `control-plugins` suite with its read-only `asks.open` RPC.

## Install

```bash
git clone https://github.com/jl97mcad/sift.git
cd sift
./install.sh        # builds ~/Applications/Sift.app and ~/.local/bin/sift
```

Building from source avoids Gatekeeper prompts: release builds are signed
ad hoc, not notarized. An agent can run the whole setup; see
[AGENTS.md](AGENTS.md).

## Setup

1. Create a self-built app at <https://open.larksuite.com/app> and enable these
   user scopes (an admin may need to approve them):

   | Scope | Used for |
   | --- | --- |
   | `im:chat:read` | chat list and details |
   | `im:message`, `im:message.send_as_user` | reading and sending as you |
   | `im:message.p2p_msg:get_as_user`, `im:message.group_msg:get_as_user` | direct and group history |
   | `im:chat.members:read` | sender names in groups |
   | `im:resource` | images and files |
   | `contact:user.base:readonly`, `contact:user:search` | names and direct-chat pictures |
   | `offline_access` | staying signed in |

2. Store the app credentials. The secret is read from stdin, never argv:

   ```bash
   printf '%s' "$APP_SECRET" | sift setup --app-id cli_xxxxxxxx --app-secret -
   ```

3. Sign in with Lark's device flow:

   ```bash
   sift login --no-wait            # prints a code and a URL to approve
   sift login --device-code CODE   # after approving in the browser
   ```

   Or press "Sign in with Lark" in the app.

4. Check it:

   ```bash
   sift doctor
   sift chats --limit 5
   ```

### Agent seats (optional)

```bash
sift agents add --agent-id <paseo-agent-id> --host tcp://<daemon-host>:<port>
sift agents add --agent-id <id> --host <host> --name "Finance" --color pink
sift agents list
```

Or use Settings → Agents. Seats sit before the Inbox in the rail, in the
order added (drag to reorder). Each gets a face: its own colour, picked from
the name unless you choose one (blue, purple, pink, orange, yellow, teal,
red). The seat named Control is what `sift control` addresses.

Sift sends with `paseo send` and keeps one connection open per seat through
the installed Paseo app's own client: Paseo's events bring a fresh, bounded,
typed timeline when something changes. Only prompts and replies show as
messages; thoughts and tool steps show as labelled, collapsed work. When a
handoff archives a seated session and exactly one live session on the same
host carries its `seat` label, that seat follows it; its name, colour, draft
and seen requests stay. Seats without a `seat` label never move.

Open asks come from each seat's daemon, through `control-plugins`' read-only
`asks.open` call. Without that suite, asks are off for that seat; if the read
fails, Sift says the state is unknown rather than showing none.

## CLI

Every command prints one JSON object and exits non-zero on failure.

| Command | Purpose |
| --- | --- |
| `sift setup --app-id ID --app-secret -` | store app credentials |
| `sift bootstrap --app-id ID [--agent-id ID --host H]` | credentials + sign-in code (+ seat) on a fresh Mac |
| `sift login [--no-wait] [--device-code CODE]` | device-flow sign-in |
| `sift status` / `sift doctor` | sign-in state; credential, token and chat checks |
| `sift chats [--limit N]` | chat list |
| `sift messages --chat-id ID [--limit N]` | one chat's history |
| `sift pins list \| add <chat_id> \| add --name "Room" \| remove <chat_id> \| clear` | pinned chats |
| `sift agents list \| add --agent-id ID [--host H] [--name N] [--color C] \| set <id\|name> \| remove <id\|name>` | agent seats |
| `sift control set \| status \| send "text" \| logs [--tail N] \| digest \| asks \| off` | the Control seat |
| `sift selftest` / `sift open` / `sift logout` | geometry self-test; open the app; forget the session |

## Privacy and data

- Everything stays on your Mac, in `~/Library/Application Support/Sift/`:
  `credentials.json` (app secret and tokens), `state.json` (pins, settings,
  agent seats) and `cache.json` (chat list and previews), each mode 0600.
  Device-only preferences use macOS user defaults.
- Sift talks only to Lark's Open API and, for each agent seat, to that
  Paseo daemon. There is no telemetry and no third-party service.
- Notifications are off until you enable them.

## How it works

- Lark has no push channel for personal messages, so Sift polls. Each tick
  reads the 20 most active chats once and fetches previews only for the top
  two and for chats that moved up; the open chat is read every tick, and pinned
  chats too while the panel is open. The interval is configurable.
- The API has no unread counter. Sift remembers the last message it showed per
  chat and marks newer messages from other people as unread.
- Direct chats list no picture and the contact profile endpoint may refuse a
  user token, so pictures come from user search, matched on the exact person.
  Otherwise initials show.

## Known limits

- Reads trail the native client by a few seconds. With the panel collapsed, a
  new message is found from the chat list's activity order, which Lark updates
  up to about 20 seconds after the message.
- The agent read depends on the Paseo desktop app's internal layout (0.14).
  A different version may fail visibly with "Paseo conversation data is
  unavailable"; Sift then falls back to reading every 15 seconds.
- Each seat keeps one Paseo helper process running (about 190 MB of memory
  each, close to no CPU at rest), so five seats cost about 1 GB.
- Agent history shows the latest 80 timeline entries, up to 400 with
  "Earlier activity"; older history stays in Paseo. Paseo artifacts are not
  shown yet.
- Stickers cannot be loaded (Lark does not serve them to apps); reactions need
  a scope that is not requested; bold and italic in posts show as plain text.
- Some people's pictures are not searchable and show initials.

## Development

```bash
swift build
CFFIXED_USER_HOME="$PWD/dist/test-home" swift test   # tests need an isolated home
.build/debug/LarkMini --cli selftest
make demo                # app with fixture data; no credentials, no network
make app                 # dist/Sift.app
make dmg                 # dist/Sift.dmg
```

`open dist/Sift.app --args --demo` accepts `--demo-chat`, `--demo-control`,
`--demo-needs-you` and `--demo-search`. Design decisions are recorded in
[docs/decisions](docs/decisions).
