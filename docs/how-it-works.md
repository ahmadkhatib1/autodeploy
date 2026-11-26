# How it works

## Flow

1. **GitLab** sends a *Push Hook* to `https://<n8n>/webhook/deploy?project=<name>` with the header `X-Gitlab-Token`.
2. **n8n** (workflow `n8n/workflow.json`) checks the event type and the format of the project name, token and ref, then opens an SSH connection to the host as `deploy` and sends `<project> <token> <ref>`.
3. On the server, that SSH key is pinned in `authorized_keys` to a **forced command**, so whatever n8n sends only reaches **`trigger.sh`** as text. It:
   - takes the last three words and checks each against a strict pattern,
   - loads the project file and compares the token,
   - ignores pushes to other branches,
   - starts `deploy.sh <project>` in the background and returns immediately (GitLab webhooks time out after 10 s).
4. **`deploy.sh`**:
   1. takes a per-project lock, so pushes queue instead of colliding;
   2. fetches the branch into a bare cache (`repo.git`) with the project's deploy key;
   3. exits quietly if that commit is already live;
   4. exports the commit into `releases/<time>-<sha>` and links shared files (`.env`, …);
   5. runs install and build there; **the live site is untouched so far**;
   6. switches the `current` symlink atomically (`mv -T`);
   7. writes a pm2 ecosystem file and restarts the app;
   8. polls the healthcheck URL; on failure it switches back to the previous release and restarts;
   9. deletes old releases and the failed one, then sends ✅ or ❌ with the last log lines.

## Failure handling

| Fails at | Live site | Notification |
|---|---|---|
| fetch / install / build | unchanged | ❌ with step and log tail; "nothing changed" |
| restart / healthcheck | previous release restored | ❌ "rolled back automatically" |
| first ever deploy, healthcheck | no previous release | ❌ "first deploy, nothing to roll back to" |

Failed releases are deleted, so `autodeploy rollback` never picks a broken one.

## Security model

- **n8n key**: `restrict,command="/opt/autodeploy/bin/trigger.sh",from="<private ranges>"`. No shell, no PTY, no forwarding, only from Docker or local networks.
- **No execution of input**: `trigger.sh` never evaluates the request. Project, token and ref must match `^[a-z0-9][a-z0-9-]{0,39}$`, `^[A-Za-z0-9]{16,128}$` and `^refs/heads/[A-Za-z0-9._/-]{1,100}$`.
- **Per-project token** (48 hex characters) and **read-only deploy key** per repository.
- **Secrets on disk** (`projects/`, `keys/`, `config/`) are mode 600/700 and owned by `deploy`.
- **Secrets not in process lists**: bot tokens, SMTP passwords and API keys are passed to `curl` through a config file descriptor, not command-line arguments.
- Config files are parsed as `KEY=value`, never `source`d.
- Every request is logged to `logs/trigger.log`.

## Running without n8n

`trigger.sh` is a normal script, so any webhook receiver that can SSH (or run a local command) can replace n8n:

```bash
sudo -u deploy /opt/autodeploy/bin/trigger.sh hisabyy <token> refs/heads/main
```
