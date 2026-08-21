create-table:
	migrate create -seq -ext=.sql -dir=./migrations create_movies_table
migrate:
	migrate -path=./migrations -database="postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" up
check-migration-version:
	migrate -path=./migrations -database="postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" version
migrate-to-version:
	migrate -path=./migrations -database="postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" goto 1
migrate-roll-back:
	migrate -path=./migrations -database="postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" down 1
migrate-down:
	migrate -path=./migrations -database="postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" down


.PHONY: monitoring/up monitoring/down

monitoring/up:
	docker compose -f ./internal/monitoring/docker-compose.yml up -d

monitoring/down:
	docker compose -f ./internal/monitoring/docker-compose.yml down

# http://localhost:4000/debug/vars   - expvar
# http://localhost:4000/metrics     - prometheus scrape endpoint
# http://localhost:9090             - prometheus UI
# http://localhost:3000             - grafana (admin/admin)