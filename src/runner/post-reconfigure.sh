#!/bin/sh
# Runs inside the GitLab container after `gitlab-ctl reconfigure`
# (GITLAB_POST_RECONFIGURE_SCRIPT). Never fails the container: errors are logged
# and gitlab-runner-init will time out with a clear message instead.

mkdir -p /bootstrap
chown git:git /bootstrap
chmod 700 /bootstrap

echo "Seeding runner bootstrap token..."
if ! gitlab-rails runner /opt/runner/seed_token.rb; then
    echo "WARNING: failed to seed runner bootstrap token"
fi
exit 0
