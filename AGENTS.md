# AGENTS.md

## Project Overview

Python 3.14 service that listens for incoming SMS messages on a GSM modem and forwards them as push notifications to a self-hosted **ntfy.sh** server. Runs in Docker via docker-compose alongside the ntfy notification server.

## Source Layout

```
sms-server/
├── sms_server/
│   ├── __init__.py       # Package marker
│   ├── __main__.py       # Entry point, signal handling, reconnect loop
│   ├── modem.py          # GSM modem: wraps vendored gsmmodem library
│   ├── notifier.py       # ntfy.sh HTTP push client (stdlib urllib)
│   ├── _gsmmodem/        # Vendored python-gsmmodem (Python 3.14 fix included)
├── cloudflared/          # Cloudflare tunnel config + credentials
│   ├── config.yml
│   └── credentials.json
├── ntfy-etc/             # ntfy server config (server.yml, user.db)
├── ntfy-cache/           # ntfy message cache (auto-created)
├── requirements.txt      # pyserial only
├── Dockerfile
├── docker-compose.yml    # ntfy + sms-server + cloudflared
├── setup.sh              # One-time setup script
├── venv/                 # Python 3.14 venv
└── AGENTS.md
```

## Commands

### Local (with venv, no Docker)

```bash
source venv/bin/activate
python -m sms_server
```

Environment variables: `SMS_PORT`, `SMS_BAUDRATE`, `NTFY_SERVER`, `NTFY_TOPIC`, `NTFY_PRIORITY`

### Docker

```bash
docker compose up -d
docker compose logs -f sms-server
docker compose down
```

### Syntax check

```bash
python -c "from sms_server.modem import Modem; from sms_server.notifier import NtfyNotifier"
```

No tests, no linter, no type checker configured.

## Dependencies

- **pyserial** — serial communication with the GSM modem
- **stdlib only** for HTTP — the notifier uses `urllib.request`, no `requests` dependency
- **Vendored gsmmodem** — `sms_server/_gsmmodem/` contains a copy of `python-gsmmodem` with a Python 3.14 fix (`.encode()` added to `serial_comms.py:write()`). The PyPI version is outdated. Absolute imports changed to relative imports in `modem.py`.

## Architecture & Data Flow

```
GSM Modem (/dev/ttyUSB2)
    │  serial (AT commands, 115200 baud)
    ▼
sms_server/_gsmmodem  ──GsmModem handles serial read thread, +CMTI notifications
    │  smsReceivedCallback(ReceivedSms)
    ▼
sms_server/modem.py  ──sms_handler → forwards to on_sms callback
    │  callback(sender, body)
    ▼
sms_server/__main__.py  ──on_sms() handler
    │
    ▼
sms_server/notifier.py  ──NtfyNotifier.notify() → HTTP POST to ntfy
    │
    ▼
ntfy server (Docker container, port 80 internal / 2586 exposed)
    │  push via WebSocket/long-poll
    ▼
ntfy mobile app (Android/iOS)
```

## Configuration (Environment Variables)

| Variable | Default | Description |
|---|---|---|
| `SMS_PORT` | `/dev/ttyUSB2` | Serial device path for the GSM modem |
| `SMS_BAUDRATE` | `115200` | Baud rate for serial communication |
| `NTFY_SERVER` | `http://localhost:2586` | ntfy server URL (use `http://ntfy:80` in Docker) |
| `NTFY_TOPIC` | `sms-forward` | ntfy topic to publish SMS notifications to |
| `NTFY_PRIORITY` | `default` | ntfy message priority (min, low, default, high, max) |

## Docker Setup

Three services in compose:

- **ntfy** — official `binwiederhier/ntfy` image, port 2586 exposed, auth enabled via `ntfy-etc/server.yml` and `ntfy-etc/user.db`
- **sms-server** — built from local Dockerfile, depends on ntfy being healthy, maps `/dev/ttyUSB2` device, uses `group_add: ["986"]` for uucp access
- **cloudflared** — official `cloudflare/cloudflared` image, mounts `cloudflared/` directory for config and credentials

The SMS container runs as non-root user `sms` with `dialout` + host uucp group for serial port access.

Volumes:
- `./ntfy-cache` — ntfy message cache
- `./ntfy-etc` — ntfy server config + user database
- `./cloudflared` — Cloudflare tunnel config + credentials

## Deployment

Run `./setup.sh` on the target server. It handles:
1. Cloudflare Tunnel login (browser) + DNS route creation
2. ntfy user/password setup
3. Docker compose build + start

On the phone: install ntfy app, server URL `https://sms.yourdomain.com`, login `admin` / your password, subscribe to `sms-forward`.

### Moving to another server

1. Copy the entire project directory
2. Run `./setup.sh` — it will create a new Cloudflare Tunnel and set up fresh credentials
3. If you want to reuse the existing tunnel, copy `cloudflared/credentials.json` and update `cloudflared/config.yml` with the tunnel UUID

## ntfy Auth

- Anonymous users: write-only (can publish notifications)
- Authenticated user `admin`: read-write to all topics (can subscribe on phone)

Config: `ntfy-etc/server.yml` and `ntfy-etc/user.db` (SQLite database).

To add users on a running instance:
```bash
docker compose exec ntfy ntfy user add --role=user <username>
docker compose exec ntfy ntfy access <username> '*' read-write
```

## Gotchas

- **Vendored gsmmodem.** The `_gsmmodem/` directory is a patched copy of `python-gsmmodem`. Do not replace it with pip-installed version — PyPI version lacks the `.encode()` call in `serial_comms.py` and breaks on Python 3.14.
- **Device GID.** The host's `/dev/ttyUSB2` is owned by `uucp` (GID 986 on Arch). The `group_add: ["986"]` in docker-compose must match. If the host uses a different GID, update it.
- **No `\r` on message body when sending.** When sending SMS programmatically, the message text must NOT end with `\r` — the termination is Ctrl+Z (`0x1A`).
- **ESC flush is mandatory.** The gsmmodem library sends `ATZ` which resets the modem. If the modem was left mid-SMS, ESC flushing is handled by the reset.
- **SIM storage leak.** The gsmmodem library auto-deletes SMS after reading them. No manual cleanup needed.
- **Reconnect loop.** On any serial error, the main loop waits 10 seconds and reconnects. No backoff or max retry limit.
- **Cloudflare Bot Fight Mode.** May block the ntfy mobile app. If the app can't connect, disable Bot Fight Mode for the subdomain in Cloudflare dashboard (Security → Bots).
- **Tunnel credentials.** `cloudflared/credentials.json` contains tunnel credentials. Keep it secret. If lost, run `setup.sh` again to create a new tunnel.
