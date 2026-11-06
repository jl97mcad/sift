# Agent setup

You are setting up Sift for the person who owns this Mac. It is a small
floating panel: pinned Lark chats, an inbox of unread chats, and an optional
Paseo Control seat with that Control's open asks. All setup is done through `sift`; there is no config
wizard to operate.

## What you may run

```bash
./install.sh                     # builds and installs app + CLI
sift setup --app-id ID --app-secret -     # secret on stdin
sift login --no-wait                       # prints user_code + URL
sift login --device-code CODE              # after the person approves
sift doctor
sift chats --limit 5
sift pins add --name "Design Room"
sift control set --agent-id ID --host tcp://host:6767
```

Every command prints one JSON object on stdout and exits non-zero on failure.
Check `ok` in the JSON, not the exit code alone.

## What needs the person

1. A Lark app in their tenant with these scopes enabled and approved:
   `im:chat:read`, `im:message`, `im:message.send_as_user`, `im:resource`,
   `im:message.p2p_msg:get_as_user`, `im:message.group_msg:get_as_user`,
   `im:chat.members:read`, `contact:user.base:readonly`, `contact:user:search`,
   `offline_access`.
2. Approving the device-flow sign-in in a browser.
3. If they want the Control seat: the Paseo desktop app on this Mac, the
   Paseo daemon host and port, and the Control agent id. Open asks also need
   that daemon to run the `control-plugins` suite with `asks.open`.

## Secrets

- Pass the app secret on stdin (`--app-secret -`) or from a file
  (`--app-secret-file`). Never in argv, never echoed, never in a log.
- Credentials are written to
  `~/Library/Application Support/Sift/credentials.json` with mode 0600.
  Do not print or copy that file.
- `bootstrap` overwrites existing credentials. On an installed machine use
  `setup` instead.

## Done means

- `sift doctor` returns `ok: true` with a chat count above zero.
- `sift status` reports `signed_in: true` and the right user.
- `open ~/Applications/Sift.app` shows the bar in the screen corner;
  clicking it opens the panel.

## Do not

- Do not modify files in this repo to make setup pass.
- Do not commit credentials or the generated app bundle.
- Do not run `bootstrap` on a machine that is already signed in.
