# Changelog

## 1.1.0 — 2026-11-26

- **GitHub support.** Each project chooses `gitlab` or `github` (`GIT_PROVIDER`, detected from the URL).
  `autodeploy add` prints the right deploy-key and webhook steps for each.
- n8n workflow accepts both GitLab and GitHub push webhooks and ignores GitHub *ping* events.
  **Upgrading:** re-import `n8n/workflow.json` in n8n and select the SSH credential again.
- `autodeploy list` shows each project's source.

## 1.0.0 — 2026-11-26

First release.

- `install.sh`: one-command server setup (Docker, Node.js, pm2, n8n, optional Caddy HTTPS).
- `autodeploy add`: register a project, generate its deploy key and webhook token.
- Release folders with atomic switch, healthcheck and automatic rollback.
- `autodeploy rollback | list | logs | remove | deploy`.
- Notifications on Telegram, email (SMTP) and WhatsApp (Cloud API / CallMeBot).
- n8n workflow with forced-command SSH access.
- End-to-end test suite (`npm test`).
