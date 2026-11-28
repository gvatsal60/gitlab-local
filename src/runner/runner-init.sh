#!/bin/sh
# Creates (or reuses) the instance runner through the GitLab REST API and writes
# its config with `gitlab-runner register`. Runs in the gitlab-runner image.
set -eu

GITLAB_URL=${GITLAB_URL:-http://gitlab:8929}
RUNNER_NAME=${RUNNER_NAME:-docker-runner}
RUNNER_TAGS=${RUNNER_TAGS:-docker,linux}
RUNNER_NETWORK=${RUNNER_NETWORK:-gitlab-local-net}
PAT_FILE=/bootstrap/runner-pat
CONFIG=/etc/gitlab-runner/config.toml
API="$GITLAB_URL/api/v4"

# Serialize concurrent runs (e.g. `make runner-register` while `make up` runs).
exec 9>/etc/gitlab-runner/.init.lock
flock 9

# 1. If the saved config holds a token GitLab still accepts, there is nothing to do.
if [ -f "$CONFIG" ]; then
  OLD_TOKEN=$(sed -n 's/^ *token = "\(.*\)"$/\1/p' "$CONFIG" | head -1)
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/runners/verify" --data-urlencode "token=$OLD_TOKEN" || true)
  if [ "$CODE" = "200" ]; then
    echo "Runner config is valid, nothing to do"
    exit 0
  fi
  echo "Saved runner token rejected (HTTP $CODE), re-registering"
fi

# 2. Wait for GitLab's API and the bootstrap token seeded by post-reconfigure.sh.
echo "Waiting for GitLab API and bootstrap token..."
i=0
until [ -s "$PAT_FILE" ] &&
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H "PRIVATE-TOKEN: $(cat "$PAT_FILE")" "$API/personal_access_tokens/self")" = "200" ]; do
  i=$((i + 1))
  if [ "$i" -ge 120 ]; then
    echo "ERROR: GitLab API or bootstrap token not ready after 20 minutes. Check 'make logs-gitlab'."
    exit 1
  fi
  sleep 10
done
PAT=$(cat "$PAT_FILE")

# 3. Delete any existing instance runners with our name, so retries and lost
#    config volumes never leave duplicates or orphans behind.
RUNNERS=$(curl -sf -H "PRIVATE-TOKEN: $PAT" "$API/runners/all?type=instance_type&per_page=100") ||
  { echo "ERROR: could not list runners"; exit 1; }
echo "$RUNNERS" | tr '{' '\n' | grep "\"description\":\"$RUNNER_NAME\"" |
  sed -n 's/.*"id":\([0-9]*\).*/\1/p' | while read -r id; do
    echo "Removing stale runner $id"
    curl -sf -X DELETE -H "PRIVATE-TOKEN: $PAT" "$API/runners/$id" || echo "WARNING: could not delete runner $id"
  done

# 4. Create the runner (tags and untagged policy are server-side settings).
RESP=$(curl -sf -X POST -H "PRIVATE-TOKEN: $PAT" "$API/user/runners" \
  --data-urlencode "runner_type=instance_type" \
  --data-urlencode "description=$RUNNER_NAME" \
  --data-urlencode "tag_list=$RUNNER_TAGS" \
  --data-urlencode "run_untagged=false") || { echo "ERROR: runner creation failed"; exit 1; }
TOKEN=$(echo "$RESP" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$TOKEN" ] || { echo "ERROR: no token in API response"; exit 1; }

# 5. Register into a temp file, then atomically move it into place.
TMP=$(mktemp /etc/gitlab-runner/config.toml.XXXXXX)
rm -f "$TMP"
trap 'rm -f "$TMP"' EXIT
gitlab-runner register --non-interactive \
  --config "$TMP" \
  --url "$GITLAB_URL" \
  --clone-url "$GITLAB_URL" \
  --token "$TOKEN" \
  --name "$RUNNER_NAME" \
  --executor docker \
  --docker-image docker:latest \
  --docker-volumes /cache \
  --docker-network-mode "$RUNNER_NETWORK"
chmod 600 "$TMP"
mv "$TMP" "$CONFIG"
echo "Runner registered successfully"
