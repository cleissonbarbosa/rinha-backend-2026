.PHONY: build up down smoke test logs

build:
	docker compose build

up:
	docker compose up -d --build

down:
	docker compose down --remove-orphans

smoke:
	curl -fsS http://localhost:9999/ready

test:
	sh scripts/official-test.sh full

official-smoke:
	sh scripts/official-test.sh smoke

logs:
	docker compose logs -f --tail=100
