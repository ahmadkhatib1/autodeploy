# Custom deploy script (`APP_TYPE=script`)

Use this when the built-in `node` / `static` flow doesn't fit: Docker Compose stacks, database
migrations, backups before every deploy, multi-tenant setups, or an existing deploy script you
already trust.

autodeploy still does the plumbing (webhook → n8n → SSH → token and branch checks, lock, log,
notifications). Instead of building a release itself, it runs **your script**, optionally as root
through a tightly scoped sudo rule.

```
push ─► n8n ─► trigger.sh ─► deploy.sh ─► [sudo -n] /opt/myapp/deploy/auto-deploy.sh
                                         └─ log + ✅ / ❌ notification with the script's output
```

## The script contract

| | |
|---|---|
| Deploy | called with **no arguments** |
| Dry run | called with **`--dry-run`**: print the plan, change nothing |
| Result | exit **0** = deployed; any other code = failed. The last 25 output lines go in the ❌ notification. |
| Responsibility | the script pulls the code, builds, migrates, restarts, and **rolls back by itself** |
| Environment | without sudo it receives `AUTODEPLOY_PROJECT`, `AUTODEPLOY_BRANCH`, `AUTODEPLOY_COMMIT`. Through sudo no environment variables are passed, so keep settings inside the script. |
| Concurrency | autodeploy never runs two deploys of the same project at once |

A ready-to-adapt template for Docker Compose is in [`examples/deploy-script-template.sh`](../examples/deploy-script-template.sh).

> An existing script that reads `DRY_RUN=1` from the environment only needs one line near the top:
> `[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=1`

## Setup

### 1. Put the script on the server

Commit it to your repository (e.g. `deploy/auto-deploy.sh`), pull it into the server's checkout, then lock it down. When it runs as root, **only root may be able to change it or its folders**:

```bash
cd /opt/myapp && git pull --ff-only
sudo chown root:root deploy/auto-deploy.sh
sudo chmod 750 deploy/auto-deploy.sh
```

### 2. Register the project

```bash
sudo autodeploy add
# or in one line:
sudo autodeploy add --name myapp --repo git@gitlab.com:me/myapp.git --branch main \
  --type script --script /opt/myapp/deploy/auto-deploy.sh --as-root yes --yes
```

| Prompt | Answer |
|---|---|
| Project name | `myapp` |
| Repository URL | `git@gitlab.com:me/myapp.git` (or GitHub) |
| Branch | `main` |
| App type | **`script`** |
| Deploy script | `/opt/myapp/deploy/auto-deploy.sh` |
| Run it as root through sudo? | `yes` (needed for Docker, `/opt`, backups…) or `no` |
| Rollback script | path, or `none` |
| Healthcheck URL | optional extra check after the script succeeds, e.g. `https://example.com/health` |

Run as root (`sudo autodeploy add`), it also:

1. **Adds the deploy key and webhook** through the GitLab / GitHub API if you saved a token (`sudo autodeploy token set`); otherwise it prints them for you to paste.
2. **Creates the sudo rule** (`/etc/sudoers.d/autodeploy-myapp`) after checking that the script is a root-owned regular file, not writable by group/others, inside folders only root can write to. The rule allows exactly:
   ```
   deploy ALL=(root) NOPASSWD: /opt/myapp/deploy/auto-deploy.sh "", /opt/myapp/deploy/auto-deploy.sh --dry-run
   ```
   No other arguments and no environment variables. If you ran `add` without sudo, or fixed permissions later: `sudo autodeploy allow-sudo myapp`.
3. **Offers a dry run** right away.

### 3. Test

```bash
autodeploy deploy myapp --dry-run   # runs your script with --dry-run
autodeploy deploy myapp             # real deploy now
autodeploy logs myapp               # latest log
```

Then push a harmless commit (e.g. a docs change) and watch n8n **Executions** and `autodeploy logs myapp`.

## Rollback

autodeploy keeps no release folders for script projects, so `autodeploy rollback myapp`:

- runs `ROLLBACK_SCRIPT` (through sudo if `DEPLOY_AS_ROOT=yes`) when you set one;
- otherwise explains that rollback belongs to your script, or to `git revert` + push.

## Notifications

- ✅ when the script exits 0 (and the optional healthcheck passes).
- ❌ with the exit code and the script's last 25 lines. autodeploy doesn't claim the site is unchanged or rolled back; your script's output says what happened.
- If sudo isn't allowed yet, the ❌ message tells you to run `sudo autodeploy allow-sudo <project>`.

## Security notes

- **Whoever can push to the deployed branch effectively has root on the server** when the script runs as root and comes from the repository: a push can change the script before it runs. Protect the branch, limit who can push, or deploy from a dedicated `production` branch.
- Keep the server's checkout (`/opt/myapp`) owned by root. `allow-sudo` refuses scripts whose file or folders others can write to.
- `autodeploy remove myapp` also disables the sudo rule.

## Settings

| Key | Description |
|---|---|
| `APP_TYPE='script'` | enables this mode |
| `DEPLOY_SCRIPT` | absolute path of the script (letters, digits, `. _ - /`) |
| `DEPLOY_AS_ROOT` | `yes` = run through `sudo -n`; `no` = run as `deploy` |
| `ROLLBACK_SCRIPT` | optional, used by `autodeploy rollback` |
| `HEALTHCHECK_URL` / `HEALTHCHECK_TIMEOUT` | optional check after a successful script |

`INSTALL_CMD`, `BUILD_CMD`, `START_CMD`, `PORT`, `SHARED_PATHS` and `KEEP_RELEASES` are not used in this mode.
