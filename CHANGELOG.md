# Changelog

## 1.0.0 — 2026-11-26

First release.

- `install.sh`: one-command server setup (Docker, Node.js, pm2, n8n, optional Caddy HTTPS).
- `autodeploy add`: register a project, generate its deploy key and webhook token.
- Release folders with atomic switch, healthcheck and automatic rollback.
- `autodeploy rollback | list | logs | remove | deploy`.
- Notifications on Telegram, email (SMTP) and WhatsApp (Cloud API / CallMeBot).
- n8n workflow with forced-command SSH access.
- End-to-end test suite (`npm test`).
