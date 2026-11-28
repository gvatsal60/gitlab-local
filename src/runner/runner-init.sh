#!/bin/sh
# Creates (or reuses) the instance runner through the GitLab REST API and writes
# its config with `gitlab-runner register`. Runs in the gitlab-runner image.
#
# Safety properties:
# - A replacement runner is created and registered before the old one is removed.
# - Only runners this script created (IDs recorded in /bootstrap) are ever deleted.
# - Only an explicit token rejection triggers re-registration; other errors retry.
set -eu

GITLAB_URL=${GITLAB_URL:-http://gitlab:8929}
RUNNER_NAME=${RUNNER_NAME:-docker-runner}
RUNNER_TAGS=${RUNNER_TAGS:-docker,linux}
RUNNER_NETWORK=${RUNNER_NETWORK:-gitlab-local-net}
RUNNER_IMAGE=${RUNNER_IMAGE:-docker:latest}
WAIT_SECS=${WAIT_SECS:-1200}

API="$GITLAB_URL/api/v4"
CONFIG=/etc/gitlab-runner/config.toml
SETTINGS_FILE=/etc/gitlab-runner/bootstrap-settings
PAT_FILE=/bootstrap/runner-pat
OWNED_FILE=/bootstrap/runner-ids
CURL="curl -s --connect-timeout 5 --max-time 30"

# Changing any of these makes a saved config stale, which triggers re-registration.
DESIRED="v1 url=$GITLAB_URL name=$RUNNER_NAME tags=$RUNNER_TAGS untagged=false network=$RUNNER_NETWORK image=$RUNNER_IMAGE"

DEADLINE=$(($(date +%s) + WAIT_SECS))
retry_or_die() {
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "ERROR: $1"
    exit 1
  fi
  sleep 10
}

# Serialize concurrent runs (e.g. `make runner-register` while `make up` runs).
exec 9>/etc/gitlab-runner/.init.lock
flock 9

# 1. Keep the saved config if its settings are current and GitLab accepts its token.
if [ -f "$CONFIG" ] && [ "$(cat "$SETTINGS_FILE" 2>/dev/null)" = "$DESIRED" ]; then
  OLD_TOKEN=$(sed -n 's/^ *token = "\(.*\)"$/\1/p' "$CONFIG" | head -1)
  echo "Verifying saved runner token..."
  while :; do
    CODE=$($CURL -o /dev/null -w '%{http_code}' -X POST "$API/runners/verify" \
      --data-urlencode "token=$OLD_TOKEN") || CODE=000
    case "$CODE" in
      200)
        echo "Runner config is valid, nothing to do"
        exit 0
        ;;
      401 | 403 | 404 | 410)
        echo "Saved runner token rejected (HTTP $CODE), re-registering"
        break
        ;;
      *) retry_or_die "could not verify runner token (last HTTP $CODE)" ;;
    esac
  done
elif [ -f "$CONFIG" ]; then
  echo "Runner settings changed, re-registering"
fi

# 2. Wait for GitLab's API and a valid bootstrap token (seeded by post-reconfigure.sh).
echo "Waiting for GitLab API and bootstrap token..."
until [ -s "$PAT_FILE" ] && [ "$($CURL -o /dev/null -w '%{http_code}' \
  -H "PRIVATE-TOKEN: $(cat "$PAT_FILE")" "$API/personal_access_tokens/self")" = "200" ]; do
  retry_or_die "GitLab API or bootstrap token not ready after ${WAIT_SECS}s. If GitLab is up, the token may have expired: run 'make runner-token', then 'make runner-register'."
done
PAT=$(cat "$PAT_FILE")

# 3. Create the replacement runner (tags and untagged policy are server-side settings).
RESP=$($CURL -f -X POST -H "PRIVATE-TOKEN: $PAT" "$API/user/runners" \
  --data-urlencode "runner_type=instance_type" \
  --data-urlencode "description=$RUNNER_NAME" \
  --data-urlencode "tag_list=$RUNNER_TAGS" \
  --data-urlencode "run_untagged=false") || {
  echo "ERROR: runner creation failed, existing runner left untouched"
  exit 1
}
NEW_ID=$(echo "$RESP" | sed -n 's/^{"id":\([0-9]*\).*/\1/p')
TOKEN=$(echo "$RESP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
if [ -z "$NEW_ID" ] || [ -z "$TOKEN" ]; then
  echo "ERROR: unexpected API response, existing runner left untouched"
  exit 1
fi
echo "Created runner $NEW_ID"

# 4. Register into a temp file, then atomically move it into place.
TMP=$(mktemp /etc/gitlab-runner/config.toml.XXXXXX)
rm -f "$TMP"
trap 'rm -f "$TMP"' EXIT
if ! gitlab-runner register --non-interactive \
  --config "$TMP" \
  --url "$GITLAB_URL" \
  --clone-url "$GITLAB_URL" \
  --token "$TOKEN" \
  --name "$RUNNER_NAME" \
  --executor docker \
  --docker-image "$RUNNER_IMAGE" \
  --docker-volumes /cache \
  --docker-network-mode "$RUNNER_NETWORK"; then
  echo "ERROR: registration failed, removing new runner $NEW_ID; existing runner left untouched"
  $CURL -o /dev/null -X DELETE -H "PRIVATE-TOKEN: $PAT" "$API/runners/$NEW_ID" || true
  exit 1
fi
chmod 600 "$TMP"
mv "$TMP" "$CONFIG"
echo "$DESIRED" >"$SETTINGS_FILE"
echo "Runner $NEW_ID registered"

# 5. Remove runners this script created earlier. Anything not recorded in
#    $OWNED_FILE, or whose description no longer matches, is never touched.
KEEP="$NEW_ID"
touch "$OWNED_FILE"
while read -r id; do
  [ -z "$id" ] || [ "$id" = "$NEW_ID" ] && continue
  CODE=$($CURL -o /tmp/runner.json -w '%{http_code}' -H "PRIVATE-TOKEN: $PAT" "$API/runners/$id") || CODE=000
  case "$CODE" in
    404) continue ;; # already gone
    200) grep -q "\"description\":\"$RUNNER_NAME\"" /tmp/runner.json || continue ;; # not ours any more
    *)
      echo "WARNING: could not check old runner $id (HTTP $CODE), will retry next run"
      KEEP="$KEEP $id"
      continue
      ;;
  esac
  CODE=$($CURL -o /dev/null -w '%{http_code}' -X DELETE -H "PRIVATE-TOKEN: $PAT" "$API/runners/$id") || CODE=000
  case "$CODE" in
    204 | 404) echo "Removed old runner $id" ;;
    *)
      echo "WARNING: could not delete old runner $id (HTTP $CODE), will retry next run"
      KEEP="$KEEP $id"
      ;;
  esac
done <"$OWNED_FILE"
# shellcheck disable=SC2086 # word-split the space-separated ID list
printf '%s\n' $KEEP >"$OWNED_FILE.tmp"
mv "$OWNED_FILE.tmp" "$OWNED_FILE"
echo "Runner configured successfully"
