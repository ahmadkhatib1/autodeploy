#!/usr/bin/env bash
# End-to-end tests for the deploy flow. No root, network, pm2 or Docker needed:
# pm2 and ssh-keygen are stubbed and the "GitLab" repo is a local bare repo.
# Requires: bash, git, node, npm, jq, curl.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
B="$ROOT/bin"
T="$(mktemp -d)"
SRV_PID=""
trap '[ -n "$SRV_PID" ] && kill "$SRV_PID" >/dev/null 2>&1; rm -rf "$T"' EXIT

export AUTODEPLOY_HOME="$T/home" AUTODEPLOY_ALLOW_ROOT=1 AUTODEPLOY_LIB="$ROOT/lib"
export NOTIFY_DRY_RUN=1 AUTODEPLOY_NONINTERACTIVE=1
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=t@t

PASS=0; FAIL=0
ok()   { echo "  ✔ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✘ $1"; FAIL=$((FAIL + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

# --- stubs -------------------------------------------------------------------
mkdir -p "$T/stub" "$T/src"
cat > "$T/stub/pm2" <<EOF
#!/usr/bin/env bash
echo "pm2 \$*" >> "$T/pm2.log"
EOF
cat > "$T/stub/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
f=""; while [[ $# -gt 0 ]]; do [[ $1 == -f ]] && f=$2; shift; done
echo "FAKE" > "$f"; echo "ssh-ed25519 AAAAFAKE test" > "$f.pub"
EOF
chmod +x "$T/stub/"*
export PATH="$T/stub:$PATH"

# --- fake app ----------------------------------------------------------------
cd "$T/src"
git init -q -b main
cat > package.json <<'EOF'
{"name":"demo","version":"1.0.0","scripts":{"build":"node -e \"require('fs').writeFileSync('built.txt','ok')\"","start":"node server.js"}}
EOF
echo 'require("http").createServer((q,s)=>s.end("hi")).listen(process.env.PORT)' > server.js
npm install --package-lock-only --silent >/dev/null 2>&1
git add -A && git commit -qm "v1" && git clone -q --bare . "$T/repo.git"

push() { git -C "$T/src" commit -qam "$1" && git -C "$T/src" push -q "$T/repo.git" main; sleep 1; }
set_build() { jq --arg b "$1" '.scripts.build=$b' "$T/src/package.json" > "$T/p" && mv "$T/p" "$T/src/package.json"; }
A="$AUTODEPLOY_HOME/apps/demo"
P="$AUTODEPLOY_HOME/projects/demo.env"
lastlog() { ls -t "$AUTODEPLOY_HOME/logs/$1"/2*.log | head -n 1; }
live() { readlink -f "$A/current"; }
PORT_A=$(( 20000 + RANDOM % 20000 ))

echo "add project + first deploy"
NAME=demo REPO_URL="$T/repo.git" PORT=$PORT_A HEALTHCHECK_URL=none NOTIFY_CHANNELS=telegram \
  "$B/add-project.sh" >/dev/null 2>&1
check "project file created with 600"   [ "$(stat -c %a "$P")" = 600 ]
check "first release is live"          [ -f "$A/current/.autodeploy-commit" ]
check "build ran"                      [ -f "$A/current/built.txt" ]
check "pm2 started"                    grep -q "startOrRestart" "$T/pm2.log"
check "success notification"           grep -q '\[notify:telegram\] ✅' "$(lastlog demo)"
V1="$(live)"
TOK="$(sed -n "s/^DEPLOY_TOKEN='\(.*\)'$/\1/p" "$P")"

echo "trigger.sh validation"
t() { SSH_ORIGINAL_COMMAND="$1" "$B/trigger.sh" 2>/dev/null; }
check "wrong token rejected"       bash -c '[[ "$(SSH_ORIGINAL_COMMAND="demo abcdefabcdefabcdef12 refs/heads/main" '"$B"'/trigger.sh)" == ERR\ unauthorized* ]]'
check "other branch skipped"       bash -c '[[ "$(SSH_ORIGINAL_COMMAND="demo '"$TOK"' refs/heads/dev" '"$B"'/trigger.sh)" == SKIP* ]]'
check "unknown project rejected"   bash -c '[[ "$(SSH_ORIGINAL_COMMAND="nope '"$TOK"' refs/heads/main" '"$B"'/trigger.sh)" == ERR\ unknown_project* ]]'
t 'demo $(touch '"$T"'/pwned) refs/heads/main' >/dev/null
t "demo;touch\${IFS}$T/pwned2 $TOK refs/heads/main" >/dev/null
check "no command injection"       [ ! -e "$T/pwned" ] && [ ! -e "$T/pwned2" ]
check "valid push queued (with cd prefix)" bash -c '[[ "$(SSH_ORIGINAL_COMMAND="cd / ; demo '"$TOK"' refs/heads/main" '"$B"'/trigger.sh)" == OK\ queued* ]]'
sleep 3
check "unchanged commit is skipped" grep -q "already live" "$(lastlog demo)"

echo "broken build keeps the live release"
set_build 'node -e "process.exit(3)"'; push "broken"
"$B/deploy.sh" demo >/dev/null 2>&1; code=$?
check "deploy exits non-zero"      [ "$code" -ne 0 ]
check "live release unchanged"     [ "$(live)" = "$V1" ]
check "failure notified once"      [ "$(grep -c '^\[notify:telegram\] ❌' "$(lastlog demo)")" = 1 ]
check "failed release removed"     [ "$(ls "$A/releases" | wc -l)" = 1 ]

echo "healthcheck failure rolls back"
set_build "echo built2"; push "v2"
sed -i "s|^HEALTHCHECK_URL=.*|HEALTHCHECK_URL='http://127.0.0.1:$PORT_A'|" "$P"
echo "HEALTHCHECK_TIMEOUT='4'" >> "$P"
"$B/deploy.sh" demo >/dev/null 2>&1
check "rolled back to v1"          [ "$(live)" = "$V1" ]
check "rollback reported"          grep -q 'تم الرجوع تلقائياً' "$(lastlog demo)"
check "bad release not kept"       [ "$(ls "$A/releases" | wc -l)" = 1 ]

echo "healthcheck success"
PORT=$PORT_A node "$T/src/server.js" >/dev/null 2>&1 & SRV_PID=$!; sleep 1
"$B/deploy.sh" demo >/dev/null 2>&1
check "new release live"           [ "$(live)" != "$V1" ]
check "healthcheck passed"         grep -q 'healthcheck OK' "$(lastlog demo)"
kill "$SRV_PID" >/dev/null 2>&1; SRV_PID=""

echo "manual rollback"
"$B/rollback.sh" demo >/dev/null 2>&1
check "rollback goes to v1"        [ "$(live)" = "$V1" ]

echo "release retention"
sed -i "s|^HEALTHCHECK_URL=.*|HEALTHCHECK_URL=''|" "$P"
for i in 1 2 3 4 5 6; do echo "// $i" >> "$T/src/server.js"; push "c$i"; "$B/deploy.sh" demo >/dev/null 2>&1; done
check "only 5 releases kept"       [ "$(ls "$A/releases" | wc -l)" = 5 ]

echo "static project + shared files"
NAME=site REPO_URL="$T/repo.git" APP_TYPE=static BUILD_CMD=none INSTALL_CMD=none "$B/add-project.sh" >/dev/null 2>&1
echo "SECRET=1" > "$AUTODEPLOY_HOME/apps/site/shared/.env"
"$B/autodeploy" deploy site >/dev/null 2>&1
check ".env linked from shared"    [ -L "$AUTODEPLOY_HOME/apps/site/current/.env" ]
check "pm2 not used for static"    bash -c '! grep -q "apps/site" "'"$T"'/pm2.log"'

echo "add-project guards"
check "duplicate port refused"     bash -c '! NAME=other REPO_URL=x PORT='"$PORT_A"' "'"$B"'/add-project.sh" >/dev/null 2>&1'
conv_out="$(NAME=conv REPO_URL=https://gitlab.com/a/b.git PORT=1234 "$B/add-project.sh" 2>&1)"
check "https URL converted to ssh"     grep -q "git@gitlab.com:a/b.git" <<<"$conv_out"
check "gitlab detected for gitlab.com"  grep -q "^GIT_PROVIDER='gitlab'" "$AUTODEPLOY_HOME/projects/conv.env"

echo "github projects"
gh_out="$(NAME=gh REPO_URL=https://github.com/me/app PORT=1235 "$B/add-project.sh" 2>&1)"
check "github detected from URL"       grep -q "^GIT_PROVIDER='github'" "$AUTODEPLOY_HOME/projects/gh.env"
check "github ssh URL"                 grep -q "^REPO_URL='git@github.com:me/app.git'" "$AUTODEPLOY_HOME/projects/gh.env"
check "github deploy-key instructions" grep -q "Add deploy key" <<<"$gh_out"
check "github webhook URL has token"   grep -qE "webhook/deploy\?project=gh&token=[a-f0-9]{48}" <<<"$gh_out"
check "github webhook uses JSON"       grep -q "application/json" <<<"$gh_out"
# (its first deploy fails because the repo doesn't exist; only the saved provider matters)
NAME=forced REPO_URL=git@code.example.com:a/b.git GIT_PROVIDER=github PORT=1236 "$B/add-project.sh" >/dev/null 2>&1
check "provider can be forced"         grep -q "^GIT_PROVIDER='github'" "$AUTODEPLOY_HOME/projects/forced.env"
check "bad provider refused"           bash -c '! NAME=badp REPO_URL=x GIT_PROVIDER=bitbucket PORT=1237 "'"$B"'/add-project.sh" >/dev/null 2>&1'
GH_TOK="$(sed -n "s/^DEPLOY_TOKEN='\(.*\)'$/\1/p" "$AUTODEPLOY_HOME/projects/gh.env")"
check "github token accepted by trigger" bash -c '[[ "$(SSH_ORIGINAL_COMMAND="gh '"$GH_TOK"' refs/heads/dev" "'"$B"'/trigger.sh")" == SKIP* ]]'

echo "n8n workflow"
WF="$ROOT/n8n/workflow.json"
check "workflow is valid JSON"         jq -e . "$WF" >/dev/null
check "normalize handles both providers" node -e '
  const wf=require(process.argv[1]);
  const set=wf.nodes.find(n=>n.type==="n8n-nodes-base.set").parameters.assignments.assignments;
  const ev=(e,$json)=>Function("$json","return "+e.replace(/^=\{\{ /,"").replace(/ \}\}$/,""))($json);
  const run=j=>Object.fromEntries(set.map(a=>[a.name,ev(a.value,j)]));
  const t="abcdefabcdefabcdef12";
  const gl=run({headers:{"x-gitlab-event":"Push Hook","x-gitlab-token":t},query:{project:"a"},body:{ref:"refs/heads/main"}});
  const gh=run({headers:{"x-github-event":"push"},query:{project:"b",token:t},body:{ref:"refs/heads/main"}});
  const form=run({headers:{"x-github-event":"push"},query:{project:"b",token:t},body:{payload:JSON.stringify({ref:"refs/heads/x"})}});
  const ping=run({headers:{"x-github-event":"ping"},query:{project:"b"},body:{}});
  const ok=gl.provider==="gitlab"&&gl.is_push&&gl.token===t&&gh.provider==="github"&&gh.is_push&&gh.token===t
         &&form.ref==="refs/heads/x"&&ping.is_push===false;
  process.exit(ok?0:1);' "$WF"

echo "script projects"
mkdir -p "$T/scripts"
cat > "$T/scripts/deploy.sh" <<EOF
#!/usr/bin/env bash
echo "args=[\$*] project=\$AUTODEPLOY_PROJECT branch=\$AUTODEPLOY_BRANCH commit=\${AUTODEPLOY_COMMIT:0:7}" >> "$T/script-calls.log"
echo "custom deploy output line"
exit \${FAKE_EXIT:-0}
EOF
cat > "$T/scripts/rollback.sh" <<EOF
#!/usr/bin/env bash
echo "rollback called" >> "$T/script-calls.log"
EOF
chmod 755 "$T/scripts/"*.sh
NAME=dock REPO_URL="$T/repo.git" APP_TYPE=script DEPLOY_SCRIPT="$T/scripts/deploy.sh" DEPLOY_AS_ROOT=no \
  ROLLBACK_SCRIPT=none HEALTHCHECK_URL=none NOTIFY_CHANNELS=telegram "$B/add-project.sh" >"$T/add-script.out" 2>&1
SP="$AUTODEPLOY_HOME/projects/dock.env"
check "script project saved"           grep -q "^APP_TYPE='script'" "$SP"
check "script path saved"              grep -q "^DEPLOY_SCRIPT='$T/scripts/deploy.sh'" "$SP"
check "no build settings for script"   bash -c '! grep -qE "^(BUILD_CMD|START_CMD|PORT)=" "'"$SP"'"'
check "add prints dry-run step"        grep -q "autodeploy deploy dock --dry-run" "$T/add-script.out"
check "no first deploy for script"     [ ! -e "$T/script-calls.log" ]

"$B/autodeploy" deploy dock --dry-run >/dev/null 2>&1; code=$?
check "dry run exits 0"                [ "$code" = 0 ]
check "dry run passes --dry-run"       grep -q "args=\[--dry-run\]" "$T/script-calls.log"
check "dry run sends no notification"  bash -c '! grep -q "^\[notify" "$(ls -t "'"$AUTODEPLOY_HOME"'/logs/dock"/2*.log | head -n1)"'

"$B/autodeploy" deploy dock >/dev/null 2>&1; code=$?
check "script deploy succeeds"         [ "$code" = 0 ]
check "script gets project/branch/commit" grep -qE "args=\[\] project=dock branch=main commit=[0-9a-f]{7}" "$T/script-calls.log"
check "success notified"               grep -q '\[notify:telegram\] ✅ تم نشر dock' "$(lastlog dock)"
check "no release folders for script"  [ ! -d "$AUTODEPLOY_HOME/apps/dock/releases" ]

FAKE_EXIT=5 "$B/deploy.sh" dock >/dev/null 2>&1; code=$?
check "script failure exit code kept"  [ "$code" = 5 ]
check "failure says script failed"     grep -q 'سكربت النشر انتهى بخطأ (exit 5)' "$(lastlog dock)"
check "failure has no misleading text" bash -c '! grep -q "لم يتغير شيء" "$(ls -t "'"$AUTODEPLOY_HOME"'/logs/dock"/2*.log | head -n1)"'
check "script output in notification"  grep -q 'custom deploy output line' "$(lastlog dock)"

sed -i "s|^HEALTHCHECK_URL=.*|HEALTHCHECK_URL='http://127.0.0.1:1'|" "$SP"; echo "HEALTHCHECK_TIMEOUT='3'" >> "$SP"
"$B/deploy.sh" dock >/dev/null 2>&1; code=$?
check "healthcheck failure after script" [ "$code" = 97 ] && grep -q 'فحص الموقع فشل' "$(lastlog dock)"
sed -i "s|^HEALTHCHECK_URL=.*|HEALTHCHECK_URL=''|" "$SP"

check "rollback without script explains" bash -c '"'"$B"'/rollback.sh" dock 2>&1 | grep -q "ROLLBACK_SCRIPT"'
sed -i "s|^ROLLBACK_SCRIPT=.*|ROLLBACK_SCRIPT='$T/scripts/rollback.sh'|" "$SP"
"$B/rollback.sh" dock >/dev/null 2>&1; code=$?
check "rollback script runs"           [ "$code" = 0 ] && grep -q "rollback called" "$T/script-calls.log"
check "dry run refused for node apps"  bash -c '! "'"$B"'/deploy.sh" demo --dry-run >/dev/null 2>&1'

echo "script projects run as root"
cat > "$T/stub/sudo" <<EOF
#!/usr/bin/env bash
[[ "\$1" == -n && "\$2" == -l ]] && exit 1
exit 0
EOF
chmod +x "$T/stub/sudo"
sed -i "s|^DEPLOY_AS_ROOT=.*|DEPLOY_AS_ROOT='yes'|" "$SP"
"$B/deploy.sh" dock >/dev/null 2>&1; code=$?
check "missing sudo rule detected"     [ "$code" = 126 ] && grep -q 'autodeploy allow-sudo dock' "$(lastlog dock)"
rm -f "$T/stub/sudo"

if [ "$(id -u)" = 0 ]; then
  echo "allow-sudo (root)"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$T/stub/visudo"; chmod +x "$T/stub/visudo"
  export SUDOERS_DIR="$T/sudoers"
  chmod 750 "$T/scripts/deploy.sh" "$T/scripts/rollback.sh"; chmod 755 "$T/scripts"
  AUTODEPLOY_USER="$(id -un)" "$B/allow-sudo.sh" dock >/dev/null 2>&1; code=$?
  check "sudo rule written"            [ "$code" = 0 ] && [ -f "$SUDOERS_DIR/autodeploy-dock" ]
  check "rule allows only exact commands" grep -qF "$T/scripts/deploy.sh \"\", $T/scripts/deploy.sh --dry-run" "$SUDOERS_DIR/autodeploy-dock"
  check "rule includes rollback script" grep -qF "$T/scripts/rollback.sh \"\"" "$SUDOERS_DIR/autodeploy-dock"
  check "rule file is 440"             [ "$(stat -c %a "$SUDOERS_DIR/autodeploy-dock")" = 440 ]
  chmod 775 "$T/scripts/deploy.sh"
  check "group-writable script refused" bash -c '! AUTODEPLOY_USER=$(id -un) "'"$B"'/allow-sudo.sh" dock >/dev/null 2>&1'
  chmod 750 "$T/scripts/deploy.sh"; chmod 777 "$T/scripts"
  check "writable folder refused"      bash -c '! AUTODEPLOY_USER=$(id -un) "'"$B"'/allow-sudo.sh" dock >/dev/null 2>&1'
  chmod 755 "$T/scripts"
  ln -s "$T/scripts/deploy.sh" "$T/scripts/link.sh"
  sed -i "s|^DEPLOY_SCRIPT=.*|DEPLOY_SCRIPT='$T/scripts/link.sh'|" "$SP"
  check "symlinked script refused"     bash -c '! AUTODEPLOY_USER=$(id -un) "'"$B"'/allow-sudo.sh" dock >/dev/null 2>&1'
  check "node project refused"         bash -c '! AUTODEPLOY_USER=$(id -un) "'"$B"'/allow-sudo.sh" demo >/dev/null 2>&1'
  "$B/autodeploy" remove dock >/dev/null 2>&1
  check "remove disables sudo rule"    [ ! -e "$SUDOERS_DIR/autodeploy-dock" ]
  unset SUDOERS_DIR
else
  echo "allow-sudo tests skipped (needs root)"
fi

echo "notification requests"
mkdir -p "$T/curlstub"
cat > "$T/curlstub/curl" <<'EOF'
#!/usr/bin/env bash
echo "ARGS: $*"
for ((i=1;i<=$#;i++)); do [[ ${!i} == -K ]] && { j=$((i+1)); cat "${!j}"; }; done
[[ " $* " == *" --upload-file - "* || " $* " == *" @- "* ]] && cat
exit 0
EOF
chmod +x "$T/curlstub/curl"
out="$(PATH="$T/curlstub:$PATH" NOTIFY_DRY_RUN=0 bash -c '
  source "'"$ROOT"'/lib/common.sh"; source "'"$ROOT"'/lib/notify.sh"
  NOTIFY_CHANNELS="telegram email whatsapp"
  TG_BOT_TOKEN=123:SECRET TG_CHAT_ID=42
  SMTP_HOST=smtp.example.com SMTP_PORT=465 SMTP_USER=u SMTP_PASS=pw SMTP_FROM=a@x EMAIL_TO=b@x
  WA_PROVIDER=cloud WA_TOKEN=WATOKEN WA_PHONE_NUMBER_ID=111 WA_TO=963900000000
  notify "subject" "body"')"
check "telegram request built"     grep -q 'api.telegram.org/bot123:SECRET/sendMessage' <<<"$out"
check "email via smtps"            grep -q 'smtps://smtp.example.com:465' <<<"$out"
check "whatsapp cloud request"     grep -q 'graph.facebook.com/.*/111/messages' <<<"$out"
check "secrets not in arguments"   bash -c '! grep "^ARGS:" <<<"$1" | grep -qE "SECRET|WATOKEN|pw"' _ "$out"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
