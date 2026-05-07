# SMS Server

Forward incoming SMS messages from a GSM modem to your phone via push notifications.

GSM modem receives SMS → self-hosted [ntfy.sh](https://ntfy.sh) server → pushed to your phone via Cloudflare Tunnel — no port forwarding needed.

## Requirements

- GSM modem (USB dongle or hat) with a SIM card
- Domain on Cloudflare (free tier works)
- Docker and `cloudflared`

## Quick Start

```bash
./setup.sh
```

The script asks for your domain, ntfy password, and starts everything.

On your phone, install the **ntfy** app:

| Setting | Value |
|---|---|
| Server URL | `https://sms.yourdomain.com` |
| Username | `admin` |
| Password | (what you typed in setup) |
| Subscribe to | `sms-forward` |

Send an SMS to the SIM — it pops up on your phone.

## Troubleshooting

**ntfy app can't connect / login fails:**
1. Cloudflare Dashboard → your domain → **Security → Bots** → disable **Bot Fight Mode**
2. Cloudflare Dashboard → your domain → **DNS → Records** → delete stale `sms` CNAME records from old tunnels

## Config

After setup, `./setup.sh` generates a `.env` file. Edit it to customize:

| Variable | Default | Description |
|---|---|---|
| `SMS_DEVICE` | `/dev/ttyUSB2` | Serial device path |
| `SMS_BAUDRATE` | `115200` | Baud rate |
| `NTFY_PORT` | `2586` | Local ntfy port |
| `NTFY_TOPIC` | `sms-forward` | Notification topic |
| `NTFY_PRIORITY` | `default` | Message priority |

The `.env` file is gitignored.

## Commands

```bash
docker compose up -d              # start
docker compose logs -f sms-server # watch SMS
docker compose down               # stop
```

## Running without Docker

```bash
pip install pyserial
NTFY_SERVER=http://localhost:2586 python -m sms_server
```

Run ntfy separately: `docker run -p 2586:80 docker.io/binwiederhier/ntfy serve`

## Migrating

Copy the whole directory, run `./setup.sh`. Creates a fresh tunnel for the new machine.
