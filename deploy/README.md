# Deploying the Sift voice service

Three pieces, one owner each:

| Piece | Where | Who writes it |
| --- | --- | --- |
| Code | `/opt/sift-voice/releases/<sha>`, `current` symlink | `deploy/install-release.sh`, from `git archive` |
| Config | `/opt/sift-voice/shared/config.json` (0640 root:sift) | Jon or Control, never a release |
| State | `/opt/sift-voice/shared/state/` (jobs, metrics) and `shared/memory/` (call notes) | the service, as `sift` |

The service runs as the `sift` user with `ProtectSystem=strict`, no new privileges and only its
state directory writable. It reads `/etc/sift-voice/openrouter-key` (0640 root:sift) and has
read-only access to `/home/paseo/.config/jons-control` for two token files. It reaches the AWS box
with its own SSH key (`/var/lib/sift/.ssh/id_ed25519`), authorised for `paseo@100.94.24.78` with the
comment `sift-voice@vps`; nothing else of root's is available to it.

## From the Mac

```sh
git -C ~/Developer/sift-service archive --format=tar.gz -o /tmp/sift-release.tar.gz <sha>
scp /tmp/sift-release.tar.gz vps:/tmp/
ssh vps "tar -xzf /tmp/sift-release.tar.gz -C /tmp/sift-deploy --strip-components=1 2>/dev/null || true"
```

Simplest: push the tarball and run the installer from a checkout of the same sha:

```sh
scp /tmp/sift-release.tar.gz vps:/tmp/
ssh vps 'install -d /tmp/sift-deploy && tar -xzf /tmp/sift-release.tar.gz -C /tmp/sift-deploy && /tmp/sift-deploy/deploy/install-release.sh <sha> /tmp/sift-release.tar.gz'
```

The installer builds dependencies, switches `current`, restarts both units (the server drains open
turns for up to 8 seconds), and keeps the last three releases.

## Checks after a deploy

```sh
curl -s http://127.0.0.1:8771/healthz          # version, key, engine, last turn
systemctl status sift-voice sift-voice-pipecat --no-pager | head -20
journalctl -u sift-voice -u sift-voice-pipecat -n 30 --no-pager
```

A live turn: `curl -sN -X POST -H 'Content-Type: application/json' -d '{"text":"say ok"}' http://127.0.0.1:8771/api/text`
or open `https://srv1452002.tailc428e4.ts.net:8453/` and tap the orb.

## Rollback

```sh
ln -sfn /opt/sift-voice/releases/<previous-sha> /opt/sift-voice/current
systemctl restart sift-voice sift-voice-pipecat
```

`shared/` is untouched, so jobs and memory survive either direction.
