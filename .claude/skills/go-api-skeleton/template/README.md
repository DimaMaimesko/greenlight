# App API

A JSON API in Go with user registration and email activation, bearer-token
authentication, per-user permissions, IP rate limiting, CORS, expvar metrics
and PostgreSQL migrations. `items` is an example resource showing the full
pattern: create, read, partial update with version checks, delete, and a
filtered, sorted, paginated list.

## Getting started

### Prerequisites

- Go (see `go.mod` for the version)
- PostgreSQL 12+ (the `citext` extension is used for emails)
- [`golang-migrate`](https://github.com/golang-migrate/migrate) CLI, e.g.
  `brew install golang-migrate`

### 1. Set up the database

```bash
psql postgres -c "CREATE ROLE app WITH LOGIN PASSWORD 'pa55word';"
psql postgres -c "CREATE DATABASE app OWNER app;"
psql app -c "CREATE EXTENSION IF NOT EXISTS citext;"
```

The `citext` extension needs a superuser, so it is created here rather than
in a migration.

### 2. Configure

```bash
cp .env.example .env
```

The API loads `.env` on startup and the `Makefile` includes it. Variables set
in the real environment take precedence; in staging and production set them
there and skip `.env`. Add SMTP credentials (for example a Mailtrap sandbox
inbox) to receive activation emails.

### 3. Migrate and run

```bash
make db/migrations/up
make run/api
```

The API listens on `:4000`. Check it with `curl localhost:4000/v1/healthcheck`.

## Configuration

Every setting is a command-line flag (`go run ./cmd/api -help` lists them).
Where an environment variable is listed, it supplies the flag's default.

| Flag | Environment variable | Default |
| --- | --- | --- |
| `-port` | `APP_PORT` | `4000` |
| `-env` | `APP_ENV` | `development` |
| `-log-level` | | `info` (`debug` also logs a line per CORS request) |
| `-db-dsn` | `APP_DB_DSN` | none, required |
| `-db-max-open-conns` / `-db-max-idle-conns` / `-db-max-idle-time` | | `25` / `25` / `15m` |
| `-limiter-rps` / `-limiter-burst` / `-limiter-enabled` | | `2` / `4` / `true` |
| `-smtp-host` / `-smtp-port` | `APP_SMTP_HOST` / `APP_SMTP_PORT` | `sandbox.smtp.mailtrap.io` / `2525` |
| `-smtp-username` / `-smtp-password` | `APP_SMTP_USERNAME` / `APP_SMTP_PASSWORD` | none |
| `-smtp-sender` | `APP_SMTP_SENDER` | `App <no-reply@example.com>` |
| `-cors-trusted-origins` | `APP_CORS_TRUSTED_ORIGINS` | none (space-separated list) |

## Endpoints

| Method | Path | Access |
| --- | --- | --- |
| GET | `/v1/healthcheck` | anyone |
| POST | `/v1/users` | anyone: register, emails an activation token |
| PUT | `/v1/users/activated` | anyone with an activation token |
| POST | `/v1/tokens/authentication` | anyone with email and password: returns a bearer token |
| GET | `/v1/items` | activated user with `items:read` |
| POST | `/v1/items` | activated user with `items:write` |
| GET | `/v1/items/:id` | activated user with `items:read` |
| PATCH | `/v1/items/:id` | activated user with `items:write` |
| DELETE | `/v1/items/:id` | activated user with `items:write` |
| GET | `/debug/vars` | anyone: expvar metrics, restrict in production |

New users get `items:read`. Grant `items:write` with psql:

```sql
INSERT INTO users_permissions
SELECT users.id, permissions.id FROM users, permissions
WHERE users.email = 'alice@example.com' AND permissions.code = 'items:write';
```

`GET /v1/items` accepts `name` (full-text search), `tags` (comma-separated,
all must match), `page`, `page_size` (max 100) and `sort` (`id`, `name`,
`created_at`, each optionally prefixed with `-` for descending).

## Make targets

```bash
make help                               # list every target
make run/api                            # run the API
make db/psql                            # open psql on the database
make db/migrations/new name=create_foo  # new pair of .sql files in ./migrations
make db/migrations/up                   # apply all migrations
make db/migrations/version              # print the current version
make db/migrations/rollback             # undo the last migration
make db/migrations/goto version=3       # move up or down to a version
make db/migrations/down                 # undo everything
make tidy                               # mod tidy, go fix, go fmt
make audit                              # mod verify, vet, staticcheck, race tests
make build/api                          # build ./bin/api and ./bin/linux_amd64/api
```

## Layout

```
cmd/api/            HTTP: main, server, routes, middleware, helpers, errors, handlers
internal/data/      models: structs, validation rules, SQL
internal/validator/ generic validation helpers
internal/mailer/    SMTP mailer and embedded email templates
migrations/         golang-migrate SQL files
```

## Removing the example resource

1. Delete `cmd/api/items.go` and `internal/data/items.go`.
2. Remove the `Items` field from `Models` and `NewModels` in
   `internal/data/models.go`.
3. Remove the `/v1/items` routes from `cmd/api/routes.go`.
4. In `cmd/api/users.go`, change or remove the `items:read` permission
   granted at registration.
5. Delete migrations `000004` to `000007`. If they are already applied, roll
   back first with `make db/migrations/goto version=3`.
