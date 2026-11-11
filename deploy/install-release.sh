#!/usr/bin/env bash
# Installs one release of the Sift voice service on the VPS. Run as root, on the VPS:
#
#   deploy/install-release.sh <sha> <release.tar.gz>
#
# The tarball is `git archive` of a committed sha (see deploy/release.sh on the Mac). A release is
# immutable: /opt/sift-voice/releases/<sha>, with `current` a symlink to it. Config, state and the
# memory notes live in /opt/sift-voice/shared, so a deploy never touches them and a rollback never
# loses a job.
set -euo pipefail

SHA=${1:?usage: install-release.sh <sha> <release.tar.gz>}
TAR=${2:?usage: install-release.sh <sha> <release.tar.gz>}
ROOT=/opt/sift-voice
DEST=$ROOT/releases/$SHA

if [[ ! -f "$DEST/VERSION" ]]; then
  rm -rf "$DEST"
  install -d -m 0755 "$DEST"
  tar -xzf "$TAR" -C "$DEST"
  echo "$SHA" > "$DEST/VERSION"
  # Dependencies at build time, so the service never installs anything while starting.
  (cd "$DEST/voice-web" && npm ci --omit=dev --no-audit --no-fund --silent)
  chown -R root:root "$DEST"
  chmod -R a+rX "$DEST"
fi

# Host-owned pieces: config, state, memory, the key, the units. Created once, never overwritten.
install -d -o sift -g sift -m 0750 "$ROOT/shared" "$ROOT/shared/state" "$ROOT/shared/memory"
if [[ ! -f "$ROOT/shared/config.json" ]]; then
  echo "install-release: $ROOT/shared/config.json is missing; copy the live config there first" >&2
  exit 1
fi
chown root:sift "$ROOT/shared/config.json"
chmod 0640 "$ROOT/shared/config.json"
if [[ ! -f /etc/sift-voice/openrouter-key ]]; then
  echo "install-release: /etc/sift-voice/openrouter-key is missing" >&2
  exit 1
fi
chown root:sift /etc/sift-voice /etc/sift-voice/openrouter-key
chmod 0750 /etc/sift-voice
chmod 0640 /etc/sift-voice/openrouter-key

install -m 0644 "$DEST/deploy/sift-voice.service" /etc/systemd/system/sift-voice.service
install -m 0644 "$DEST/deploy/sift-voice-pipecat.service" /etc/systemd/system/sift-voice-pipecat.service
# The old drop-ins belong to the root install; the units above carry their settings now.
rm -rf /etc/systemd/system/sift-voice.service.d /etc/systemd/system/sift-voice-pipecat.service.d
systemctl daemon-reload

ln -sfn "$DEST" "$ROOT/current"
systemctl restart sift-voice sift-voice-pipecat

# Keep the last three releases; the live one and its two predecessors cover a rollback.
mapfile -t OLD < <(ls -1dt "$ROOT"/releases/* | tail -n +4)
for dir in "${OLD[@]:-}"; do [[ -n "$dir" ]] && rm -rf "$dir"; done

echo "installed $SHA -> $ROOT/current"
