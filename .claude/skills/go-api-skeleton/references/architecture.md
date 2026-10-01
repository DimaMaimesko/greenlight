# Architecture

How a project in this style is laid out, and the rules that keep it that way.
The style comes from Alex Edwards' *Let's Go Further*, as implemented in the
reference project (greenlight, a movies API). File paths below are relative to
the project root and exist in every project scaffolded by this skill.

## Layout

```
cmd/
  api/                  package main: everything HTTP
    main.go             config struct, flag parsing, openDB(), wiring, expvar
    server.go           serve(): http.Server, timeouts, graceful shutdown
    routes.go           routes(): every route and the middleware chain, in one place
    middleware.go       every middleware, as methods on *application
    helpers.go          envelope, writeJSON, readJSON, readIDParam, query-string readers, background()
    errors.go           logError, errorResponse, one named helper per error response
    context.go          request-context key and get/set helpers
    healthcheck.go      GET /v1/healthcheck
    <resource>.go       handlers for one resource: movies.go, users.go, tokens.go
  examples/             throwaway programs, e.g. cors/simple (a page to test CORS from a browser)
internal/
  data/                 domain structs, validation rules, SQL
    models.go           Models struct, NewModels(db), shared sentinel errors
    filters.go          Filters, Metadata, pagination and sort helpers
    <resource>.go       one file per table: struct, Validate<Resource>(), <Resource>Model
  validator/            generic Validator and check helpers, no domain knowledge
  mailer/               SMTP mailer with embedded templates
    templates/          *.tmpl, each defining subject, plainBody and htmlBody
migrations/             golang-migrate files: 00000N_name.up.sql / .down.sql
docs/openapi.yaml       hand-written API spec, updated alongside the handlers (optional)
Makefile                help, run/api, db/..., tidy, audit, build/api
.env.example            every environment variable, committed; .env itself is git-ignored
```

## Rules

- **Each directory under `cmd/` is one binary.** `cmd/api` is `package main`
  and owns everything about HTTP: routing, JSON, status codes, middleware.
  Nothing in `internal/` imports `net/http` request handling or knows about
  envelopes.
- **Reusable code lives in `internal/`.** Go only allows packages rooted at
  the module to import it, so it can't become someone else's dependency.
- **Imports point one way:** `cmd/api` → `internal/data` → `internal/validator`.
  `internal/mailer` stands alone. Never import `cmd/...`, never import upward.
- **No mutable package-level state.** Dependencies live on the `application`
  struct and are built in `main()`. The only package-level values are
  constants, sentinel errors, compiled regexps (`validator.EmailRX`), embedded
  files (`mailer.templateFS`) and expvar metrics (expvar is global by design).
- **Handlers, helpers and middleware are methods on `*application`**, so they
  reach config, logger, models and mailer without globals.
- **Standard library first.** Each third-party module has one job the standard
  library doesn't do well enough:

  | Module | Job |
  | --- | --- |
  | `julienschmidt/httprouter` | method routing with `:params`; custom `NotFound` / `MethodNotAllowed` handlers so 404 and 405 come back as JSON |
  | `lib/pq` | Postgres driver for `database/sql`, plus `pq.Array` and `*pq.Error` codes |
  | `golang.org/x/crypto/bcrypt` | password hashing |
  | `golang.org/x/time/rate` | token-bucket rate limiter |
  | `tomasen/realip` | client IP behind proxies |
  | `wneessen/go-mail` | SMTP client |
  | `joho/godotenv` | load `.env` in development |
  | `honnef.co/go/tools` (as a `go tool`) | staticcheck in `make audit` |

  Never add a web framework, ORM, query builder, DI container, config
  library, logging library (use `log/slog`) or validation library.

## The application struct (`cmd/api/main.go`)

```go
type application struct {
	config config
	logger *slog.Logger
	models data.Models
	mailer *mailer.Mailer
	wg     sync.WaitGroup
}
```

A new dependency is a new field here, built in `main()`. `wg` tracks
background goroutines so shutdown can wait for them (see `background()` in
handlers.md).

## Startup (`main()` in `cmd/api/main.go`)

1. `_ = godotenv.Load()`: load `.env` if present; a missing file is fine.
2. Parse flags into `config`, with defaults read from environment variables
   (config.md).
3. Build the `slog` logger at the configured level.
4. Check required settings and exit with a message that says how to fix it.
5. `openDB(cfg)`: `sql.Open`, pool limits, then `PingContext` with a 5-second
   timeout so a bad DSN fails at startup, not on the first request.
6. Build the other dependencies (mailer).
7. Publish expvar metrics: `version`, `goroutines`, `database` (`db.Stats()`),
   `timestamp`.
8. Build `application` and call `app.serve()`.

Any startup error: `logger.Error(err.Error())` then `os.Exit(1)`. `main()` is
the only function that exits the process.

## Server and shutdown (`cmd/api/server.go`)

- `http.Server` always has explicit timeouts (`IdleTimeout` 1m, `ReadTimeout`
  5s, `WriteTimeout` 10s) and routes its `ErrorLog` into slog with
  `slog.NewLogLogger(app.logger.Handler(), slog.LevelError)`.
- A goroutine waits for SIGINT/SIGTERM, logs `stopping server`, calls
  `srv.Shutdown` and sends the result on a channel.
- `ListenAndServe` returns `http.ErrServerClosed` once shutdown starts; that is
  the normal path. Any other error is returned at once.
- After `Shutdown` returns, `app.wg.Wait()` lets background tasks finish, then
  `shutdown complete` is logged.
- **Known gap:** the reference project calls `srv.Shutdown(context.Background())`,
  which has no deadline, so one stuck connection blocks shutdown forever. The
  book uses `context.WithTimeout(context.Background(), 30*time.Second)`; prefer
  that in new code.

## Naming

| Thing | Pattern | Examples |
| --- | --- | --- |
| Handler | `<verb><Resource>Handler` | `createMovieHandler`, `listMoviesHandler`, `activateUserHandler` |
| Error response | `<situation>Response` | `notFoundResponse`, `editConflictResponse` |
| Model | `<Resource>Model`, plural field in `Models` | `MovieModel`, `app.models.Movies` |
| Validation | `Validate<Thing>(v, thing)` in `internal/data` | `ValidateMovie`, `ValidateEmail` |
| Middleware | what it does | `recoverPanic`, `rateLimit`, `authenticate`, `enableCORS`, `metrics` |
| Route | `/v1/` + plural noun; actions as sub-resources | `/v1/movies/:id`, `PUT /v1/users/activated`, `POST /v1/tokens/authentication` |

## Code style

- Return early on errors. `err := f()` and `if err != nil` sit on separate
  lines; the one exception is the validator idiom
  `if data.ValidateMovie(v, movie); !v.Valid() {`.
- Map errors with `switch { case errors.Is(err, ...): ... default: ... }`,
  even when there is only one case, so adding another is a one-line change.
- Comments are full sentences above the code. Match the density of the file
  you are editing.
- `make tidy` (mod tidy, `go fix`, `go fmt`) and `make audit` (mod verify,
  vet, staticcheck, race tests) must both pass before committing.
