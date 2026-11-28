# All targets are phony. "all" is the default target (same as `make up`).
.PHONY: all test health up down logs logs-gitlab logs-runner ps restart build pull clean config status runner-status runner-verify runner-register runner-token runner-shell shell stop start

COMPOSE := docker compose --project-directory src

all: up

# Validate the Compose file (needs GITLAB_ROOT_PASSWORD set).
test:
	$(COMPOSE) config -q

up:
	$(COMPOSE) up -d

down:
	$(COMPOSE) down

logs:
	$(COMPOSE) logs -f

logs-gitlab:
	$(COMPOSE) logs -f gitlab

logs-runner:
	$(COMPOSE) logs -f gitlab-runner

ps:
	$(COMPOSE) ps

restart:
	$(COMPOSE) restart

# Services use prebuilt images, so "build" refreshes them.
build: pull

pull:
	$(COMPOSE) pull

clean:
	$(COMPOSE) down -v --remove-orphans

config:
	$(COMPOSE) config

status: ps health
	@echo "=== Runner Verify ==="
	@$(COMPOSE) exec gitlab-runner gitlab-runner verify || echo "Runner not verified"

health:
	@echo "=== GitLab Health ==="
	@$(COMPOSE) exec gitlab /opt/gitlab/embedded/bin/curl -fsS http://localhost:8929/-/health || echo "GitLab not ready"

shell:
	$(COMPOSE) exec gitlab bash

runner-shell:
	$(COMPOSE) exec gitlab-runner bash

runner-status:
	@$(COMPOSE) ps gitlab-runner-init gitlab-runner
	@$(COMPOSE) exec gitlab-runner gitlab-runner verify

runner-verify:
	$(COMPOSE) exec gitlab-runner gitlab-runner verify

runner-register:
	$(COMPOSE) run --rm gitlab-runner-init

# Re-seed the runner bootstrap token (e.g. after it expired) without restarting GitLab.
runner-token:
	$(COMPOSE) exec gitlab sh /opt/runner/post-reconfigure.sh

stop:
	$(COMPOSE) stop

start:
	$(COMPOSE) start
