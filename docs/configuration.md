# Configuration reference

All settings are plain `KEY='value'` files. They are read, never executed, so they can't run code by accident.

## Per-project: `/opt/autodeploy/projects/<name>.env`

Created by `autodeploy add`. Edit with `sudo -u deploy nano /opt/autodeploy/projects/<name>.env`; changes apply on the next deploy.

| Key | Default | Description |
|---|---|---|
| `GIT_PROVIDER` | detected | `gitlab` or `github`. Detected from the URL (`github` if the host contains "github"); only changes the setup instructions `autodeploy add` prints. |
| `REPO_URL` | (required) | SSH URL, e.g. `git@gitlab.com:group/app.git` or `git@github.com:me/app.git`. Self-hosted GitLab and GitHub Enterprise work too. |
| `BRANCH` | `main` | The only branch whose pushes trigger a deploy. |
| `APP_TYPE` | `node` | `node` = run with pm2. `static` = only build; serve `current/` with your web server. `script` = run your own deploy script ([guide](custom-script.md)). |
| `DEPLOY_SCRIPT` | | `script` only: absolute path of the deploy script. |
| `DEPLOY_AS_ROOT` | `no` | `script` only: `yes` runs it through `sudo -n` (set up with `sudo autodeploy allow-sudo <name>`). |
| `ROLLBACK_SCRIPT` | | `script` only, optional: run by `autodeploy rollback <name>`. |
| `INSTALL_CMD` | `auto` | `auto` picks `pnpm install --frozen-lockfile`, `yarn install`, `bun install`, `npm ci` or `npm install` from the lockfile. `none` skips the step. |
| `BUILD_CMD` | `npm run build` | Runs inside the new release folder. `none` skips it. |
| `START_CMD` | `npm start` | Command pm2 keeps running. `none` for static sites. |
| `PORT` | `3000` | Exported as `PORT` to the build and the app. Must be unique per project. |
| `HEALTHCHECK_URL` | empty | Polled after restart; if it doesn't return 2xx/3xx in time, the deploy rolls back. Empty = no check. |
| `HEALTHCHECK_TIMEOUT` | `60` | Seconds to wait for the healthcheck. |
| `KEEP_RELEASES` | `5` | Older release folders are deleted. The live one is never deleted. |
| `SHARED_PATHS` | `.env .env.local .env.production` | Files or folders in `apps/<name>/shared/` that are symlinked into each release (e.g. add `uploads`). |
| `PM2_NAME` | project name | pm2 process name. |
| `NOTIFY_CHANNELS` | server default | Override channels for this project, e.g. `telegram` or `email whatsapp`. |
| `DEPLOY_TOKEN` | generated | GitLab: the webhook "Secret token". GitHub: the `token=` value in the webhook URL. |

### Examples

**Next.js app**

```
INSTALL_CMD='auto'
BUILD_CMD='npm run build'
START_CMD='npm start'
PORT='3000'
HEALTHCHECK_URL='http://127.0.0.1:3000'
```

**Vite / React static site** (serve `/opt/autodeploy/apps/<name>/current/dist` with Nginx or Caddy)

```
APP_TYPE='static'
BUILD_CMD='npm run build'
START_CMD='none'
```

**Monorepo with pnpm**

```
INSTALL_CMD='corepack pnpm install --frozen-lockfile'
BUILD_CMD='corepack pnpm --filter web build'
START_CMD='corepack pnpm --filter web start'
```

## Server-wide

| File | Purpose |
|---|---|
| `config/notify.env` | Notification channels and credentials (see [notifications.md](notifications.md)). Mode 600. |
| `config/server.env` | `WEBHOOK_BASE`, the n8n webhook URL printed by `autodeploy add`. |
| `config/known_hosts` | GitLab host keys, learned on first fetch. |
| `n8n/.env` | n8n settings (domain, encryption key). Keep a backup of `N8N_ENCRYPTION_KEY`. |
| `n8n/docker-compose.yml` | n8n (and Caddy when a domain is set). |

## Environment variables for the scripts

| Variable | Default | Use |
|---|---|---|
| `AUTODEPLOY_HOME` | `/opt/autodeploy` | Install location. |
| `AUTODEPLOY_USER` | `deploy` | User that owns apps and runs pm2. |
| `NODE_MAJOR` | `22` | Node.js version installed by `install.sh`. |
| `N8N_DOMAIN` | asked | Pre-answer the domain question in `install.sh`. |
| `AUTODEPLOY_NONINTERACTIVE` | unset | `1` = accept defaults instead of prompting (same as `add --yes`). |
| `AUTODEPLOY_TOKENS_DIR` | `/etc/autodeploy/tokens` | Where `autodeploy token set` stores API tokens (root-only). |
| `CONNECT_RETRIES` | `5` | How many times `connect` checks deploy-key access (2 s apart). |

Every `autodeploy add` prompt can also be pre-answered with an env var of the same name:

```bash
NAME=hisabyy REPO_URL=git@gitlab.com:me/hisabyy.git PORT=3001 autodeploy add
```

## Folder layout

```
/opt/autodeploy/
├── bin/  lib/           scripts
├── config/              notify.env, server.env, known_hosts
├── projects/<name>.env  project settings + token
├── keys/<name>          deploy keys (GitLab / GitHub)
├── apps/<name>/
│   ├── current -> releases/<live>
│   ├── releases/        last N releases
│   ├── shared/          .env and persistent files
│   └── repo.git         bare cache of the repository
├── logs/<name>/         one log per deploy + app.out/err.log
└── n8n/                 docker-compose, workflow.json, n8n SSH key
```
