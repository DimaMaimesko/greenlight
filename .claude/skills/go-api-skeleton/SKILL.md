---
name: go-api-skeleton
description: Scaffold and extend Go JSON APIs in the style of Alex Edwards' Let's Go Further (the greenlight project) - standard library first, httprouter, PostgreSQL through database/sql and golang-migrate, flags with environment-variable defaults, JSON envelope and error helpers, CORS, rate limiting, graceful shutdown, and stateful token auth with email activation and permissions. Ships a tested project template, a scaffold script and convention guides. Use it whenever the user wants to start a new Go REST or JSON API, backend service or project template, or to add resources, endpoints, migrations, middleware, settings or auth to a Go API with a cmd/api and internal/data layout, even if they never mention the book or ask for a skeleton. Not for Go web apps that render HTML pages, CLI tools, or projects built on a framework such as Gin, Echo or Fiber.
compatibility: Go 1.26+ and make. Running the API needs PostgreSQL and the golang-migrate CLI; scripts/verify.sh also needs psql, curl and jq.
---

# Go API skeleton

This skill builds Go JSON APIs the way *Let's Go Further* teaches: plain
`net/http` and `database/sql`, a handful of small dependencies, and a fixed
place for everything. It comes with:

- `template/`: a complete, tested API (users, activation, login, permissions,
  and an example `items` resource) that compiles as its own module.
- `scripts/scaffold.sh`: copies the template into a new project and renames
  the module path, environment variable prefix, database and display name.
- `scripts/verify.sh`: scaffolds a throwaway copy and checks it end to end
  against PostgreSQL. For maintaining the skill (see the last section).
- `references/`: the conventions, one file per layer, to read when you work
  on that layer.

Paths below are relative to this skill's base directory unless they name a
file inside the user's project.

## Which job is this?

- **A new project** (nothing exists yet, or an empty directory): follow
  "Starting a new project".
- **An existing project in this style** (a `go.mod`, `cmd/api/routes.go`,
  `internal/data/models.go`): follow "Changing an existing project". Read the
  project's own code first: it may differ from the template in names (an
  older project might use `movies` and a `GREENLIGHT_` prefix) and where it
  does, match the project.

## Starting a new project

1. **Settle the names.** You need a Go module path. If the user hasn't given
   one, ask, suggesting `github.com/<their-user>/<project>`. Everything else
   has a sensible default derived from the module path, so only ask about the
   directory, display name, env prefix or database name if the user cares.
   Note any resources the request names (books, orders...) and their fields.
   If it names none, the user wants the base template: don't ask, keep the
   example `items` resource, and skip step 3.

2. **Scaffold with the script**, never by copying files or writing the
   skeleton from memory. The script renames consistently, keeps imports
   formatted, and fails if any placeholder survives:

   ```bash
   <skill-dir>/scripts/scaffold.sh --module github.com/acme/bookstore --dir ./bookstore
   # optional: --name "Book Store" --prefix BOOKSTORE --db bookstore
   ```

3. **Replace the example with the user's resources.** `items` exists to be
   copied, in this order:
   1. Copy `internal/data/items.go` and `cmd/api/items.go` to each new
      resource's names (`books.go`...). These copies are your starting point.
   2. Remove `items`: its two Go files, its migrations `000004` to `000007`,
      the `Items` field in `internal/data/models.go`, the `/v1/items` routes,
      and the `items:read` grant in `registerUserHandler` (the project
      README's "Removing the example resource" lists them). Doing this before
      creating any migration makes the new ones number from `000004`;
      `references/migrations.md` still shows the items SQL as a pattern.
   3. Build each resource with the "Add a resource" checklist in
      `references/recipes.md`, adapting the copies while keeping their
      structure: the same steps in each handler, the same model methods, the
      same error mapping. Grant the new read permission at registration if
      that suits the API.

   Keep `items` (skip 2) only if the user wants it kept as a reference.

4. **Update the project's README** if you replaced `items`: the endpoint
   table, the query parameters, the permission example, and drop the
   "Removing the example resource" section.

5. **Check it** (see "Checking your work"), then tell the user how to run
   it: the database commands printed by the scaffold script, `cp .env.example
   .env`, `make db/migrations/up`, `make run/api`. Offer to run them if
   PostgreSQL and `migrate` are installed; creating databases on their
   machine is their call.

## Changing an existing project

Read the reference for the layer you are touching before editing it. They
are short and describe the rules the existing code already follows:

| You are working on | Read |
| --- | --- |
| Package layout, `main()`, the `application` struct, shutdown, adding a dependency | `references/architecture.md` |
| Handlers, JSON in and out, status codes, error responses, background work | `references/handlers.md` |
| Models, SQL, validation, filtering, sorting, pagination | `references/data-models.md` |
| Routes, middleware, CORS, rate limiting, metrics | `references/middleware.md` |
| Users, passwords, tokens, activation, permissions, emails | `references/auth.md` |
| Settings, environment variables, `.env`, logging, expvar | `references/config.md` |
| Schema changes and migrations | `references/migrations.md` |
| Tests for validation, parsers and custom types | `references/testing.md` |
| A common change from start to finish | `references/recipes.md` |

For anything that touches several layers (a new resource, a new field, a
new token type), start from `references/recipes.md`; each step names the
reference with the details.

If the project keeps hand-written API docs (a `docs/openapi.yaml`, endpoint
tables or curl examples in the README), update them in the same change;
nothing generates them.

## The conventions that matter most

These hold the style together. The references explain each in full.

- **Standard library first.** `net/http`, `database/sql`, `encoding/json`,
  `log/slog`, `flag`, `expvar`. The only dependencies are httprouter, lib/pq,
  bcrypt, x/time/rate, realip, go-mail and godotenv. Don't add a web
  framework, ORM, query builder, config or logging library: every helper in
  the project assumes plain `http.Handler` and `*sql.DB`, and a framework
  would make half of them dead code.
- **Dependencies hang off `application`.** Handlers, helpers and middleware
  are methods on `*application`; new dependencies become fields built in
  `main()`. No package-level mutable state, so every piece can be read in
  isolation.
- **Handlers follow the same steps:** an anonymous input struct, `readJSON`,
  copy into the domain struct, `Validate<Thing>`, model call with
  `errors.Is` mapping, `writeJSON` with an `envelope`. Decoding into a
  separate input struct is what stops clients from setting IDs and versions.
- **Every error goes through a named helper in `cmd/api/errors.go`.**
  Unexpected errors go to `serverErrorResponse`, which logs the detail and
  sends a generic message, so internals never leak to clients.
- **Models take and return values**, give each query a 3-second timeout,
  and translate driver errors into `ErrRecordNotFound`, `ErrEditConflict` or
  a resource-specific error, so handlers never see `database/sql` types.
  Models don't log.
- **Updatable tables have a `version` column** checked in `UPDATE ... WHERE
  version = $n`, and updates are `PATCH` with pointer fields in the input
  struct, so a missing field is distinguishable from a zero value.
- **SQL always uses placeholders.** The one interpolation, `ORDER BY`, only
  takes values from a safelist.
- **The schema changes only through new migrations**, with a matching
  `down`, and `CHECK` constraints mirror the Go validation rules. Never edit
  a migration that has been applied.
- **Goroutines start through `app.background()`**, so they recover from
  panics and graceful shutdown waits for them.
- **Settings are flags whose defaults come from environment variables**;
  secrets have no default in code, and every variable is listed in
  `.env.example`.
- **Tokens are stored as SHA-256 hashes**, passwords as bcrypt hashes, and
  neither plaintext is ever stored or logged.
- **New validation and parsing logic comes with table-driven tests**, written
  by default rather than on request: that is where the edge cases are, and
  the tests need no database, so `make audit` runs them every time.

## Checking your work

Do these in the project before saying the work is done:

1. **Write table-driven tests** for every `Validate<Thing>`, parser and
   custom JSON type you added or changed, in a `_test.go` file next to it,
   with the standard `testing` package only. Cover the valid case and both
   sides of every limit. Don't wait to be asked: the user wants them unless
   they say otherwise. `references/testing.md` has the pattern. Tests that
   need a database or a running server are a bigger step; offer those
   instead of adding them unasked.
2. `make tidy`, then `make audit` (vet, staticcheck, and the tests with the
   race detector). Both must pass.
3. If PostgreSQL is available: `make db/migrations/up`, and for new
   migrations also `make db/migrations/rollback` followed by `up` again, to
   prove the `down` file works.
4. Start the API and exercise each new or changed endpoint with curl,
   including the error paths: missing auth (401), missing permission (403),
   unknown id (404), invalid input (422), bad JSON (400).

## Maintaining this skill

`template/` is a normal Go module: edit it, then run `scripts/verify.sh`. It
scaffolds a throwaway project and runs about 60 checks against a real
PostgreSQL (it needs a superuser through `PGHOST`/`PGUSER`/`PGPASSWORD`) and
cleans up afterwards. When the template gains a new place where the module
path, prefix, database or display name appears, teach `scripts/scaffold.sh`
about it; its leftover check will fail until you do. Keep `references/` in
step with the template, since they quote it.
