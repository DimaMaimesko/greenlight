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

.PHONY: load/light load/heavy load/errors

# Gentle load — stays under the rate limiter if you run the API with a higher rps,
# e.g. go run ./cmd/api -limiter-rps=100 -limiter-burst=200
load/light:
	hey -z 60s -q 10 -c 5 http://localhost:4000/v1/healthcheck

# Heavy load — good for watching latency percentiles and in-flight requests
load/heavy:
	hey -z 60s -c 50 http://localhost:4000/v1/healthcheck

# Trigger the ManyRateLimitedRequests alert: run API with default limiter (2 rps)
load/errors:
	hey -z 90s -q 50 -c 10 http://localhost:4000/v1/healthcheck

# http://localhost:4000/debug/vars   - expvar
# http://localhost:4000/metrics     - prometheus scrape endpoint
# http://localhost:9090             - prometheus UI
# http://localhost:9093             - alertmanager UI
# http://localhost:3000             - grafana (admin/admin)