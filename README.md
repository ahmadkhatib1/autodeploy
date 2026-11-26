# autodeploy

**English** · [العربية](README.ar.md)

Self-hosted auto-deploy from **GitLab or GitHub** to **your own server**, orchestrated by **n8n**.
Push to a branch → the server pulls, builds and releases the new version → you get a message on **Telegram, email or WhatsApp**.

```
GitLab / GitHub push ──► n8n webhook ──► SSH (forced command) ──► trigger.sh ──► deploy.sh
                                                                        ├─ git fetch
                                                                        ├─ install + build in a fresh release folder
                                                                        ├─ atomic switch of the "current" symlink
                                                                        ├─ pm2 restart + healthcheck
                                                                        └─ notify ✅ / ❌ (auto-rollback on failure)
```

- **One tool, many projects.** Add a project with `autodeploy add`; it prints the deploy key, webhook URL and secret for GitLab or GitHub.
- **Safe releases.** Every deploy builds in its own folder. A failed build never touches the live site.
- **Automatic rollback.** If the app fails its healthcheck after the switch, the previous release is restored.
- **Manual rollback** in one command, with the last 5 releases kept.
- **Locked-down n8n access.** n8n's SSH key can only run the trigger script, only from Docker networks.
- **Per-project secrets.** Each project has its own webhook token and a read-only deploy key.
- **Notifications** on Telegram, email (any SMTP) and WhatsApp (Cloud API or CallMeBot). You choose them at install time and can change them per project.

Works with Next.js, Node.js APIs, Vite/React static sites, or anything with an install/build/start command.

---

## Requirements

- Ubuntu 22.04 / 24.04 or Debian, with root access.
- Recommended: a domain for n8n (e.g. `n8n.example.com`) pointing to the server, for HTTPS webhooks.

## Install (once per server)

With npm (Node.js 18+ already on the server):

```bash
sudo npx @ahmadkhatib/autodeploy install
```

Or with Git (no Node needed, the installer sets it up):

```bash
git clone https://github.com/ahmadkhatib1/autodeploy.git
cd autodeploy
sudo bash install.sh
```

The installer sets up Git, Docker, Node.js 22, pm2 and n8n (in Docker), creates a `deploy` user, then asks:

1. **n8n domain**: enter it for automatic HTTPS (Caddy), or leave empty to use `http://SERVER_IP:5678`.
2. **Notification channels**: Telegram, email and/or WhatsApp, then sends a test message.

## Finish n8n setup (once, ~3 minutes)

The installer prints these steps at the end:

1. Open n8n and create the owner account.
2. **Credentials → Add credential → SSH Private Key**
   - Name `autodeploy server`, Host `host.docker.internal`, Port `22`, Username `deploy`
   - Private key: `sudo cat /opt/autodeploy/n8n/n8n_ssh_key`
3. Import the workflow: `cat /opt/autodeploy/n8n/workflow.json`, copy it and paste (Ctrl+V) into an empty n8n canvas.
4. Open the **Run deploy on server** node, select the credential, save, and switch the workflow to **Active**.

## Add a project

```bash
sudo autodeploy add
```

Run with `sudo` so autodeploy can finish everything itself: add the deploy key and webhook through the API (once you've saved a token, see below), create the sudo rule for script projects, then run the first deploy or dry run.

| Prompt | Example |
|---|---|
| Project name | `hisabyy` |
| Repository URL | `git@gitlab.com:you/hisabyy.git` or `https://github.com/you/site` (https URLs are converted) |
| Git provider | `gitlab` or `github` (detected from the URL) |
| Branch | `main` |
| App type | `node` (run with pm2), `static` (files only) or `script` (your own deploy script, see below) |
| Install command | `auto` (detects npm / pnpm / yarn / bun) |
| Build command | `npm run build` |
| Start command | `npm start` |
| Port | `3000` (unique per project) |
| Healthcheck URL | `http://127.0.0.1:3000` or `none` |
| Notifications | empty = server default, or e.g. `telegram` |

Every prompt can also be given as a flag, which makes adding a project a single command:

```bash
sudo autodeploy add --name shop --repo git@gitlab.com:me/shop.git --branch main \
  --type script --script /opt/shop/deploy/auto-deploy.sh --as-root yes \
  --health https://shop.example.com/health --yes
```

Flags: `--name --repo --provider --branch --type --install --build --start --port --health --script --as-root --rollback --notify`, plus `--yes` to accept defaults for anything not given.

### Automatic GitLab / GitHub setup (recommended)

Save an API token for your Git host once:

```bash
sudo autodeploy token set              # gitlab.com
sudo autodeploy token set github.com
sudo autodeploy token set gitlab.mycompany.com   # self-hosted works too
```

From then on, `sudo autodeploy add` (and `sudo autodeploy connect <project>` for existing projects) adds the read-only **deploy key** and the push-only **webhook** for you, checks that the key can read the branch, and re-uses the existing webhook if you run it again.

| Host | Token |
|---|---|
| GitLab | personal, group or project access token with the `api` scope and **Maintainer** role on the project |
| GitHub | fine-grained token limited to your repos with **Administration** and **Webhooks**: read & write (or classic: `repo` + `admin:repo_hook`) |

Tokens are verified before saving and stored root-only in `/etc/autodeploy/tokens/<host>.token` (mode 600). They are never printed or passed on a command line. `autodeploy remove <project>` also deletes the deploy key and webhook. Manage tokens with `token list | test [host] | remove <host>`.

### Manual setup

Without a token, autodeploy prints exactly what to paste for the provider you chose.

**GitLab**

1. **Settings → Repository → Deploy keys**: paste the printed public key (no write access). The script waits and verifies access.
2. **Settings → Webhooks**:
   - URL: `https://n8n.example.com/webhook/deploy?project=hisabyy`
   - Secret token: the printed token
   - Trigger: **Push events**, branch filter `main`

**GitHub**

1. **Settings → Deploy keys → Add deploy key**: paste the printed public key, leave *Allow write access* off.
2. **Settings → Webhooks → Add webhook**:
   - Payload URL: `https://n8n.example.com/webhook/deploy?project=site&token=<printed token>`
   - Content type: `application/json`
   - Secret: leave empty
   - Events: **Just the push event**

> GitHub has no plain secret header, so the token is part of the URL. Use n8n over HTTPS (set a domain at install).

App secrets go in `/opt/autodeploy/apps/<project>/shared/.env` and are linked into every release.

Test it with a push, or with GitLab's **Webhooks → Test → Push events**. GitHub sends a *ping* when the webhook is created; n8n ignores it, and the next push deploys.

## Option: your own deploy script (Docker Compose, migrations, backups)

When a project needs more than install → build → restart, choose **App type `script`**. autodeploy keeps the webhook, checks, lock, logs and notifications, and runs your script instead of its own build. If needed it runs it as root through a sudo rule limited to that one file.

```bash
sudo autodeploy add          # App type: script, Deploy script: /opt/myapp/deploy/auto-deploy.sh
autodeploy deploy myapp --dry-run
```

Your script is called with no arguments to deploy, or with `--dry-run` to print its plan. Exit 0 means deployed; anything else is reported as a failure with the script's output. The script handles its own rollback.

Full guide, contract and security notes: [docs/custom-script.md](docs/custom-script.md). Template: [examples/deploy-script-template.sh](examples/deploy-script-template.sh).

## Commands

```bash
sudo autodeploy add [flags]        # register a project (asks for anything not given)
sudo autodeploy connect <project>  # (re)create deploy key + webhook via API, sudo rule, first run
sudo autodeploy token set [host]   # save a GitLab / GitHub API token (also: list, test, remove)
autodeploy list                    # projects and their live release
autodeploy deploy <project>        # deploy now
autodeploy deploy <project> --dry-run   # script projects: show the plan only
autodeploy rollback <project> [r]  # back to the previous (or a given) release
sudo autodeploy allow-sudo <project>    # script projects: (re)create the sudo rule
autodeploy logs <project>          # latest deploy log
sudo autodeploy remove <project>   # unregister; with a token also deletes key + webhook (files are kept)
autodeploy notify-setup            # choose / change notification channels
autodeploy notify-test             # send a test message
autodeploy info                    # paths and webhook base URL
```

App output: `/opt/autodeploy/logs/<project>/app.out.log` and `app.err.log`, or `sudo -u deploy pm2 logs <project>`.

## Documentation

- [Configuration reference](docs/configuration.md): every per-project and server setting
- [Custom deploy script](docs/custom-script.md): `APP_TYPE=script` for Docker Compose and other setups
- [How it works & security](docs/how-it-works.md)
- [Notifications setup](docs/notifications.md): Telegram, Gmail/SMTP, WhatsApp
- [Changelog](CHANGELOG.md)

## Troubleshooting

| Symptom | Fix |
|---|---|
| Nothing happens on push | GitLab: Webhooks → **Recent events**. GitHub: Webhooks → **Recent Deliveries**. Then n8n → **Executions**. |
| `ERR unauthorized` in the execution | The token (GitLab secret token, or `token=` in the GitHub URL) ≠ `DEPLOY_TOKEN` in the project file. |
| `SKIP branch …` | The push was to a branch this project doesn't deploy. |
| `git fetch` fails | The deploy key is missing or not enabled for that repository. |
| Healthcheck fails | The app isn't listening on `PORT`; check `app.err.log`, or raise `HEALTHCHECK_TIMEOUT`. |
| n8n can't connect over SSH | Make sure `sshd` is running and port 22 is reachable from the Docker network. |

## Development

```bash
npm test        # end-to-end tests (no root, Docker or network needed)
npm run lint    # bash syntax check
```

Releases: bump `version` in `package.json`, then create a GitHub release tagged `vX.Y.Z`. The publish workflow runs the tests and publishes to npm (needs an `NPM_TOKEN` repository secret).

## License

[MIT](LICENSE) © Ahmad Khatib
