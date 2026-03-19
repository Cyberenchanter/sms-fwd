# SMS Forward Proxy Server

A lightweight, resilient message forwarding proxy that accepts HTTPS POST JSON requests and forwards them to Telegram via the Bot API.

Built with **Go** — zero external dependencies, single binary deployment.

## Features

- 🔒 TLS support with automatic Let's Encrypt certificates via acme.sh
- 🔑 Bearer token authentication
- 🔄 Automatic retries with quadratic backoff (up to 3 retries)
- 🛡️ Rate-limit aware (respects Telegram 429 responses)
- 📏 Request size limiting (64KB max payload)
- 🪵 Structured JSON logging (`log/slog`)
- 🛑 Graceful shutdown on SIGINT/SIGTERM
- 🔧 Customizable API endpoint path
- 📦 Zero external dependencies — stdlib only

## Quick Start (Automated)

Run the setup script on your Linux server:

```bash
git clone https://github.com/Cyberenchanter/sms-fwd.git
sudo bash sms-fwd/install.sh
```

The script will:
1. Install Go via `apt` or `pacman`
2. Prompt for all configuration values
3. Optionally set up TLS with Let's Encrypt (auto-renewable via acme.sh)
4. Build the binary and install to `/opt/sms-fwd`
5. Create and start a systemd service

## Manual Setup

### 1. Prerequisites

- Go 1.22+
- A [Telegram Bot Token](https://core.telegram.org/bots#how-do-i-create-a-bot)
- Your Telegram Chat ID

### 2. Build

```bash
cd server
go build -o sms-fwd-server .
```

### 3. Configure

Set environment variables:

| Variable             | Required | Default     | Description                          |
|----------------------|----------|-------------|--------------------------------------|
| `TELEGRAM_BOT_TOKEN` | ✅       | —           | Telegram Bot API token               |
| `TELEGRAM_CHAT_ID`   | ✅       | —           | Your Telegram chat ID                |
| `AUTH_TOKEN`          | No       | —           | Bearer token for request auth        |
| `LISTEN_ADDR`        | No       | `:10086`    | Server listen address                |
| `API_PATH`           | No       | `/forward`  | API endpoint path                    |
| `TLS_CERT_FILE`      | No       | `cert.pem`  | Path to TLS certificate              |
| `TLS_KEY_FILE`       | No       | `key.pem`   | Path to TLS private key              |

### 4. Run

```bash
export TELEGRAM_BOT_TOKEN="123456:ABC-DEF..."
export TELEGRAM_CHAT_ID="123456789"
export AUTH_TOKEN="my-secret-token"

./sms-fwd-server
```

### 5. Get Your Chat ID

Message your bot on Telegram (send `/start`), then run:

```bash
curl -s "https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates" | jq '.result[0].message.chat.id'
```

Set the returned numeric ID as `TELEGRAM_CHAT_ID`. This ensures messages are only forwarded to you.

## API

### `POST /forward`

Forward a message to Telegram. The endpoint path is customizable via `API_PATH`.

**Headers:**
```
Content-Type: application/json
Authorization: Bearer <AUTH_TOKEN>
```

**Request Body:**
```json
{
  "from": "+1234567890",
  "subject": "Verification Code",
  "body": "Your code is 123456"
}
```

| Field     | Required | Description                                      |
|-----------|----------|--------------------------------------------------|
| `body`    | ✅       | Message content                                  |
| `from`    | No       | Sender identifier (shown in formatted message)   |
| `subject` | No       | Subject/title line                                |

**Responses:** HTTP status codes only, no response body.

| Status | Meaning                              |
|--------|--------------------------------------|
| `200`  | Message forwarded successfully       |
| `400`  | Invalid request (bad JSON, empty body) |
| `401`  | Invalid or missing authorization     |
| `405`  | Method not allowed (use POST)        |
| `502`  | Failed to forward to Telegram        |

## Example: Send via curl

```bash
curl -X POST https://your-domain.com:10086/forward \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer my-secret-token" \
  -d '{
    "from": "+1 (555) 123-4567",
    "subject": "Verification",
    "body": "Your verification code is 847291"
  }'
```

## Telegram Message Format

Messages are formatted as:

```
📱 From: +1 (555) 123-4567
📌 Verification
─────────────
Your verification code is 847291
```

## Service Management

```bash
sudo systemctl status sms-fwd-server
sudo systemctl restart sms-fwd-server
sudo systemctl stop sms-fwd-server
sudo journalctl -u sms-fwd-server -f
```

Edit config and restart:

```bash
sudo nano /opt/sms-fwd/start.sh
sudo systemctl restart sms-fwd-server
```