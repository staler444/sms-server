# SMS Server

Forward incoming SMS messages from a GSM modem to your phone via push notifications.

**How it works:** GSM modem receives SMS → sent to a self-hosted [ntfy.sh](https://ntfy.sh) server → pushed to your phone instantly over the internet via Cloudflare Tunnel (no port forwarding needed).

## Requirements

- A GSM modem (USB dongle or hat) with a SIM card
- A domain on Cloudflare (free tier works)
- Docker and `cloudflared` installed

## Quick Start

```bash
./setup.sh
```

The script walks you through:
1. Cloudflare login (browser opens once)
2. Domain configuration (e.g. `sms.yourdomain.com`)
3. ntfy password setup

Then it starts everything in Docker. After that, install the **ntfy** app on your phone:

| Setting | Value |
|---|---|
| Server URL | `https://sms.yourdomain.com` |
| Username | `admin` |
| Password | (what you set in setup.sh) |
| Subscribe to | `sms-forward` |

Send an SMS to the SIM in the modem — it'll pop up on your phone.

## Architecture

```
Phone sends SMS → GSM Modem (/dev/ttyUSB2) → sms-server (Python) → ntfy (Docker) → Cloudflare Tunnel → Your phone
```

Three Docker containers:
- **ntfy** — notification server with auth
- **sms-server** — listens to the modem, forwards to ntfy
- **cloudflared** — secure tunnel (no open ports on your router)

## Commands

```bash
docker compose up -d              # start everything
docker compose logs -f sms-server # watch SMS traffic
docker compose down               # stop everything
```

## Running without Docker

```bash
source venv/bin/activate
NTFY_SERVER=http://localhost:2586 python -m sms_server
```

You'll need to run ntfy separately (e.g. `docker run -p 2586:80 binwiederhier/ntfy serve`).

## Migrating to another server

Copy the whole directory and run `./setup.sh` again. It creates a new Cloudflare tunnel for that machine.
