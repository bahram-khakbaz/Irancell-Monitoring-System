up:
	docker compose up -d --build

down:
	docker compose down

logs:
	docker logs -f irancell_scraper

run:
	docker compose run --rm scraper
