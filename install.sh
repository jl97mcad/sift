#!/usr/bin/env bash
# Install Sift from a fresh checkout. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift toolchain not found. Install Xcode or the Command Line Tools first." >&2
  exit 1
fi

make install

cat <<'TEXT'

Installed
  ~/Applications/Sift.app
  ~/.local/bin/sift

Next, in this order (an agent can run all of it):

  1. Create a Lark app at https://open.larksuite.com/app and enable:
       im:chat:read, im:message, im:message.send_as_user, im:resource,
       im:message.p2p_msg:get_as_user, im:message.group_msg:get_as_user,
       im:chat.members:read, contact:user.base:readonly, contact:user:search,
       offline_access
     Copy the App ID and App Secret.

  2. Store the credentials. The secret goes in on stdin, never argv:
       printf '%s' "$APP_SECRET" | sift setup --app-id cli_xxx --app-secret -

  3. Sign in. This prints a code and a URL for the person to approve:
       sift login --no-wait
       sift login --device-code <device_code>

  4. Check it:
       sift doctor
       sift chats --limit 5

  5. Optional Control seat (Paseo):
       sift control set --agent-id <id> --host tcp://<host>:6767

  6. Open the app:
       open ~/Applications/Sift.app

Secrets live in ~/Library/Application Support/Sift/credentials.json (0600).
Never print them. `bootstrap` overwrites credentials; on an existing install use
`setup` instead.
TEXT
