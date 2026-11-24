.PHONY: up down logs ps restart build pull clean config status runner-status runner-verify shell

COMPOSE := docker compose --project-directory src

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

build:
	$(COMPOSE) build --no-cache

pull:
	$(COMPOSE) pull

clean:
	$(COMPOSE) down -v --remove-orphans

config:
	$(COMPOSE) config

status:
	@echo "=== Containers ==="
	$(COMPOSE) ps
	@echo ""
	@echo "=== GitLab Health ==="
	@$(COMPOSE) exec gitlab /opt/gitlab/embedded/bin/curl -fsS http://localhost:8929/-/health || echo "GitLab not ready"
	@echo ""
	@echo "=== Runner Verify ==="
	@$(COMPOSE) exec gitlab-runner gitlab-runner verify || echo "Runner not verified"

shell:
	$(COMPOSE) exec gitlab bash

runner-shell:
	$(COMPOSE) exec gitlab-runner bash

runner-verify:
	$(COMPOSE) exec gitlab-runner gitlab-runner verify

runner-register:
	$(COMPOSE) run --rm gitlab-runner-init

stop:
	$(COMPOSE) stop

start:
	$(COMPOSE) start
