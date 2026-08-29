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

include .env

# ==================================================================================== #
# HELPERS
# ==================================================================================== #

## help: print this help message
.PHONY: help
help:
	@echo 'Usage:'
	@sed -n 's/^##//p' ${MAKEFILE_LIST} | column -t -s ':' |  sed -e 's/^/ /'

.PHONY: confirm
confirm:
	@echo -n 'Are you sure? [y/N] ' && read ans && [ $${ans:-N} = y ]

# ==================================================================================== #
# DEVELOPMENT
# ==================================================================================== #

## run/api: run the cmd/api application
.PHONY: run/api
run/api:
	go run ./cmd/api -db-dsn=${GREENLIGHT_DB_DSN}

## db/psql: connect to the database using psql
.PHONY: db/psql
db/psql:
	psql ${GREENLIGHT_DB_DSN}

## db/migrations/new name=$1: create a new database migration
.PHONY: db/migrations/new
db/migrations/new:
	migrate create -seq -ext=.sql -dir=./migrations ${name}

## db/migrations/up: apply all up database migrations
.PHONY: db/migrations/up
db/migrations/up: confirm
	migrate -path ./migrations -database ${GREENLIGHT_DB_DSN} up

# ==================================================================================== #
# QUALITY CONTROL
# ==================================================================================== #

## tidy: tidy module dependencies, and format and modernize all .go files
.PHONY: tidy
tidy:
	go mod tidy
	go fix ./...
	go fmt ./...

## audit: run quality control checks
.PHONY: audit
audit:
	go mod tidy -diff
	go mod verify
	go vet ./...
	go tool staticcheck ./...
	go test -race -vet=off ./...

# ==================================================================================== #
# BUILD
# ==================================================================================== #

## build/api: build the cmd/api application
.PHONY: build/api
build/api:
	go build -ldflags='-s' -o=./bin/api ./cmd/api
	GOOS=linux GOARCH=amd64 go build -ldflags='-s' -o=./bin/linux_amd64/api ./cmd/api