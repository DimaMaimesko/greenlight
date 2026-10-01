# Load .env when present so make targets share the same configuration as the
# API. Variables already set in the real environment take precedence, and so
# does anything passed on the command line, e.g.
#   make db/migrations/up APP_DB_DSN="postgres://user:pass@host/db?sslmode=disable"
ifneq (,$(wildcard .env))
include .env
export
endif

APP_DB_DSN ?= postgres://app:pa55word@localhost/app?sslmode=disable

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
	go run ./cmd/api -db-dsn="${APP_DB_DSN}"

## db/psql: connect to the database using psql
.PHONY: db/psql
db/psql:
	psql "${APP_DB_DSN}"

## db/migrations/new name=$1: create a new database migration
.PHONY: db/migrations/new
db/migrations/new:
	migrate create -seq -ext=.sql -dir=./migrations ${name}

## db/migrations/up: apply all up database migrations
.PHONY: db/migrations/up
db/migrations/up: confirm
	migrate -path ./migrations -database "${APP_DB_DSN}" up

## db/migrations/version: print the current database migration version
.PHONY: db/migrations/version
db/migrations/version:
	migrate -path ./migrations -database "${APP_DB_DSN}" version

## db/migrations/goto version=$1: migrate up or down to a specific version
.PHONY: db/migrations/goto
db/migrations/goto: confirm
	migrate -path ./migrations -database "${APP_DB_DSN}" goto ${version}

## db/migrations/rollback: roll back the most recent database migration
.PHONY: db/migrations/rollback
db/migrations/rollback: confirm
	migrate -path ./migrations -database "${APP_DB_DSN}" down 1

## db/migrations/down: roll back all database migrations
.PHONY: db/migrations/down
db/migrations/down: confirm
	migrate -path ./migrations -database "${APP_DB_DSN}" down -all

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
