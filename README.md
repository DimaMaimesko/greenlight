# Greenlight API

A JSON API for managing movie records, with user registration and activation,
bearer-token authentication, per-user permissions, IP rate limiting, CORS and
expvar metrics.

## Getting started

### Prerequisites

- Go 1.26+ (see `go.mod`)
- PostgreSQL 12+ (the `citext` extension is used for emails)
- [`golang-migrate`](https://github.com/golang-migrate/migrate) CLI — `brew install golang-migrate`
- `jq`, for the scripted curl snippets further down — `brew install jq`

### 1. Set up the database

The defaults everywhere (the `-db-dsn` flag and every `make` target) assume
`postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable`:

```bash
psql postgres -c "CREATE ROLE greenlight WITH LOGIN PASSWORD 'pa55word';"
psql postgres -c "CREATE DATABASE greenlight OWNER greenlight;"
psql greenlight -c "CREATE EXTENSION IF NOT EXISTS citext;"
```

The `citext` extension has no migration of its own, so it has to be created
before the migrations run.

### 2. Run the migrations

```bash
make migrate                   # apply all migrations
make check-migration-version   # print the current version
make migrate-roll-back         # undo the last migration
make migrate-down              # undo everything
make create-table              # scaffold a new pair of .sql files in ./migrations
```

Each target hardcodes the DSN above — edit the `Makefile` if yours differs.

### 3. Run the API

```bash
go run ./cmd/api
```

It listens on `:4000` and logs `database connection pool established` on a
successful start. Two variants are handy while working through the flows below:

```bash
# the default limiter is 2 rps / burst 4, which the scripted flows will trip:
go run ./cmd/api -limiter-enabled=false
# needed only for the CORS flow at the end:
go run ./cmd/api -cors-trusted-origins="http://localhost:9000"
```

### Configuration flags

| Flag | Default |
| --- | --- |
| `-port` | `4000` |
| `-env` | `development` |
| `-log-level` | `info` — `debug` also logs a line per CORS request |
| `-db-dsn` | `postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable` |
| `-db-max-open-conns` | `25` |
| `-db-max-idle-conns` | `25` |
| `-db-max-idle-time` | `15m` |
| `-limiter-rps` | `2` |
| `-limiter-burst` | `4` |
| `-limiter-enabled` | `true` |
| `-smtp-host` / `-smtp-port` | `sandbox.smtp.mailtrap.io` / `2525` |
| `-smtp-username` / `-smtp-password` | Mailtrap sandbox credentials |
| `-smtp-sender` | `Greenlight <no-reply@dima.maimesko.com>` |
| `-cors-trusted-origins` | empty (space-separated list) |

The SMTP defaults point at a Mailtrap sandbox inbox, so welcome and activation
emails land there rather than in a real mailbox — swap in your own credentials
to send for real.

## API reference

The full OpenAPI 3.1 spec lives in [`docs/openapi.yaml`](docs/openapi.yaml) —
every endpoint, parameter, request body, response envelope and error shape. It
is hand-written rather than generated, so it needs updating alongside the
handlers. The API does not serve it; view it with any OpenAPI viewer, e.g.:

```bash
# render it as a browsable HTML page and open it
npx @redocly/cli build-docs docs/openapi.yaml -o docs/api.html
open docs/api.html

# check it still validates after an edit
npx @redocly/cli lint docs/openapi.yaml
```

`docs/api.html` is generated output — regenerate it after editing the spec, or
delete it and view the YAML in [editor.swagger.io](https://editor.swagger.io)
instead. The page inlines the spec but pulls the Redoc renderer from a CDN, so
it needs a network connection to display.

The rest of this file is the same API as a set of runnable curl flows.

## User flows (curl)

Base URL assumes the API is running locally on the default port:

```bash
export BASE=http://localhost:4000
```

Endpoints (from `cmd/api/routes.go`):

| Method | Path | Auth |
| --- | --- | --- |
| GET | `/v1/healthcheck` | none |
| POST | `/v1/users` | none |
| PUT | `/v1/users/activated` | none (activation token in body) |
| POST | `/v1/tokens/authentication` | none (email + password in body) |
| GET | `/v1/movies` | activated + `movies:read` |
| POST | `/v1/movies` | activated + `movies:write` |
| GET | `/v1/movies/:id` | activated + `movies:read` |
| PATCH | `/v1/movies/:id` | activated + `movies:write` |
| DELETE | `/v1/movies/:id` | activated + `movies:write` |
| GET | `/debug/vars` | none |

---

## Flow 1 — New user: register → activate → log in

### 1.1 Health check (is the API up?)

```bash
curl -i $BASE/v1/healthcheck
```

### 1.2 Register

Name is required (max 500 bytes), email must be valid, password 8–72 bytes.
Returns `202 Accepted`; the account starts with `"activated": false` and is
automatically granted the `movies:read` permission.

```bash
curl -i -X POST $BASE/v1/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Alice Smith","email":"alice@example.com","password":"pa55word1234"}'
```

An activation token (valid 3 days) is emailed in the background via SMTP —
with the default flags that is the Mailtrap sandbox inbox. Only the hash is
stored in the database, so the plaintext token has to come from that email.

### 1.3 Activate

```bash
export ACTIVATION_TOKEN=<26-char token from the welcome email>

curl -i -X PUT $BASE/v1/users/activated \
  -H "Content-Type: application/json" \
  -d "{\"token\":\"$ACTIVATION_TOKEN\"}"
```

Response echoes the user with `"activated": true`. All activation tokens for
that user are then deleted, so replaying this call returns a 422.

### 1.4 Log in (get an authentication token)

Returns `201` with a 24-hour bearer token.

```bash
curl -i -X POST $BASE/v1/tokens/authentication \
  -H "Content-Type: application/json" \
  -d '{"email":"alice@example.com","password":"pa55word1234"}'
```

Capture it straight into a variable (needs `jq`):

```bash
export TOKEN=$(curl -s -X POST $BASE/v1/tokens/authentication \
  -H "Content-Type: application/json" \
  -d '{"email":"alice@example.com","password":"pa55word1234"}' \
  | jq -r '.authentication_token.token')

echo $TOKEN
```

---

## Flow 2 — Reader: browsing movies

Every call below needs `Authorization: Bearer <token>` and an activated
account with `movies:read` (granted at registration).

### 2.1 List movies (defaults: page 1, page_size 20, sort id)

```bash
curl -i -H "Authorization: Bearer $TOKEN" "$BASE/v1/movies"
```

### 2.2 Full-text search on the title

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/v1/movies?title=black+panther" | jq
```

### 2.3 Filter by genres (CSV, movie must contain all of them)

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/v1/movies?genres=adventure,action" | jq
```

### 2.4 Paginate and sort

`sort` safelist: `id`, `title`, `year`, `runtime` and each prefixed with `-`
for descending. `page_size` max is 100, `page` max is 10 million.

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/v1/movies?page=2&page_size=5&sort=-year" | jq '.metadata'
```

### 2.5 Everything combined

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/v1/movies?title=panther&genres=action&page=1&page_size=10&sort=-runtime" | jq
```

### 2.6 Show one movie

```bash
curl -i -H "Authorization: Bearer $TOKEN" "$BASE/v1/movies/1"
```

---

## Flow 3 — Editor: create, update, delete a movie

Registration only grants `movies:read`, so these calls return
`403 "your user account doesn't have the necessary permissions"` until
`movies:write` is granted. There is no endpoint for that — do it in psql:

```bash
psql "postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" -c \
  "INSERT INTO users_permissions
   SELECT users.id, permissions.id FROM users, permissions
   WHERE users.email = 'alice@example.com' AND permissions.code = 'movies:write';"
```

The existing token stays valid — permissions are read per request.

### 3.1 Create

`runtime` must be the string `"<n> mins"`. 1–5 unique genres, year between
1888 and the current year. Returns `201` plus a `Location` header.

```bash
curl -i -X POST $BASE/v1/movies \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Black Panther","year":2018,"runtime":"134 mins","genres":["action","adventure"]}'
```

Grab the new id:

```bash
export MOVIE_ID=$(curl -s -X POST $BASE/v1/movies \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"title":"Deadpool","year":2016,"runtime":"108 mins","genres":["action","comedy"]}' \
  | jq -r '.movie.id')

echo $MOVIE_ID
```

### 3.2 Partial update

`PATCH` semantics: omitted fields are left alone.

```bash
curl -i -X PATCH $BASE/v1/movies/$MOVIE_ID \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"year":2017}'
```

Replace the genres only:

```bash
curl -i -X PATCH $BASE/v1/movies/$MOVIE_ID \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"genres":["comedy","action","sci-fi"]}'
```

### 3.3 Delete

```bash
curl -i -X DELETE $BASE/v1/movies/$MOVIE_ID \
  -H "Authorization: Bearer $TOKEN"
```

### 3.4 Full create → read → update → delete round trip

```bash
ID=$(curl -s -X POST $BASE/v1/movies \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Moana","year":2016,"runtime":"107 mins","genres":["animation","adventure"]}' \
  | jq -r '.movie.id')

curl -s -H "Authorization: Bearer $TOKEN" "$BASE/v1/movies/$ID" | jq

curl -s -X PATCH "$BASE/v1/movies/$ID" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"runtime":"110 mins"}' | jq

curl -s -X DELETE "$BASE/v1/movies/$ID" -H "Authorization: Bearer $TOKEN" | jq
```

---

## Flow 4 — Error paths worth exercising

### 4.1 No token → 401 "you must be authenticated to access this resource"

```bash
curl -i $BASE/v1/movies
```

### 4.2 Malformed Authorization header → 401 + `WWW-Authenticate: Bearer`

```bash
curl -i -H "Authorization: $TOKEN" $BASE/v1/movies          # missing "Bearer "
curl -i -H "Authorization: Bearer not-a-real-token" $BASE/v1/movies
```

### 4.3 Registered but not activated → 403 "your user account must be activated"

```bash
curl -s -X POST $BASE/v1/users -H "Content-Type: application/json" \
  -d '{"name":"Bob Jones","email":"bob@example.com","password":"pa55word1234"}'

BOB=$(curl -s -X POST $BASE/v1/tokens/authentication -H "Content-Type: application/json" \
  -d '{"email":"bob@example.com","password":"pa55word1234"}' | jq -r '.authentication_token.token')

curl -i -H "Authorization: Bearer $BOB" $BASE/v1/movies
```

### 4.4 Missing permission → 403

```bash
curl -i -X POST $BASE/v1/movies \
  -H "Authorization: Bearer $BOB_ACTIVATED" \
  -H "Content-Type: application/json" \
  -d '{"title":"Test","year":2020,"runtime":"90 mins","genres":["drama"]}'
```

### 4.5 Wrong credentials → 401 "invalid authentication credentials"

```bash
curl -i -X POST $BASE/v1/tokens/authentication \
  -H "Content-Type: application/json" \
  -d '{"email":"alice@example.com","password":"wrongpassword"}'
```

### 4.6 Duplicate email → 422

```bash
curl -i -X POST $BASE/v1/users -H "Content-Type: application/json" \
  -d '{"name":"Alice Again","email":"alice@example.com","password":"pa55word1234"}'
```

### 4.7 Validation failures → 422 with a per-field error map

```bash
# empty name, bad email, short password
curl -i -X POST $BASE/v1/users -H "Content-Type: application/json" \
  -d '{"name":"","email":"not-an-email","password":"short"}'

# bad year / runtime format / too many genres
curl -i -X POST $BASE/v1/movies \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"title":"Too Old","year":1000,"runtime":"134 minutes","genres":["a","b","c","d","e","f"]}'

# invalid sort value
curl -i -H "Authorization: Bearer $TOKEN" "$BASE/v1/movies?sort=director"
```

### 4.8 Malformed / unknown-field JSON → 400

```bash
curl -i -X POST $BASE/v1/users -H "Content-Type: application/json" \
  -d '{"name": "Alice",'

curl -i -X POST $BASE/v1/users -H "Content-Type: application/json" \
  -d '{"name":"Alice","email":"a@b.com","password":"pa55word1234","rating":9}'
```

### 4.9 Unknown route / wrong method → 404 / 405

```bash
curl -i $BASE/v1/foo
curl -i -X DELETE $BASE/v1/healthcheck
```

### 4.10 Rate limiter → 429 "rate limit exceeded"

Defaults are 2 rps with a burst of 4, keyed by IP:

```bash
for i in $(seq 1 10); do curl -s -o /dev/null -w "%{http_code}\n" $BASE/v1/healthcheck; done
```

---

## Flow 5 — Ops: metrics and CORS

### 5.1 Runtime metrics (expvar)

```bash
curl -s $BASE/debug/vars | jq
curl -s $BASE/debug/vars | jq '{version, goroutines, total_requests_received, total_responses_sent}'
curl -s $BASE/debug/vars | jq '.database'
```

### 5.2 Simple CORS request

Only origins passed to `-cors-trusted-origins` get an
`Access-Control-Allow-Origin` header back:

```bash
curl -i -H "Origin: http://localhost:9000" $BASE/v1/healthcheck   # allowed
curl -i -H "Origin: http://evil.example.com" $BASE/v1/healthcheck # no ACAO header
```

### 5.3 Preflight request

```bash
curl -i -X OPTIONS $BASE/v1/movies/1 \
  -H "Origin: http://localhost:9000" \
  -H "Access-Control-Request-Method: PATCH" \
  -H "Access-Control-Request-Headers: Authorization, Content-Type"
```

The browser-side demo page that exercises this lives in
`cmd/examples/cors/simple` (`go run ./cmd/examples/cors/simple`).
