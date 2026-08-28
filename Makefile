# Load .env when present so make targets share the same configuration as the
# API. Variables already set in the real environment take precedence, and so
# does anything passed on the command line, e.g.
#   make migrate GREENLIGHT_DB_DSN="postgres://user:pass@host/db?sslmode=disable"
ifneq (,$(wildcard .env))
include .env
export
endif

GREENLIGHT_DB_DSN ?= postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable

.PHONY: create-table
create-table:
	migrate create -seq -ext=.sql -dir=./migrations create_movies_table

.PHONY: migrate
migrate:
	migrate -path=./migrations -database="$(GREENLIGHT_DB_DSN)" up

.PHONY: check-migration-version
check-migration-version:
	migrate -path=./migrations -database="$(GREENLIGHT_DB_DSN)" version

.PHONY: migrate-to-version
migrate-to-version:
	migrate -path=./migrations -database="$(GREENLIGHT_DB_DSN)" goto 1

.PHONY: migrate-roll-back
migrate-roll-back:
	migrate -path=./migrations -database="$(GREENLIGHT_DB_DSN)" down 1

.PHONY: migrate-down
migrate-down:
	migrate -path=./migrations -database="$(GREENLIGHT_DB_DSN)" down

.PHONY: run
run:
	go run ./cmd/api

.PHONY: psql
psql:
	psql "$(GREENLIGHT_DB_DSN)"
