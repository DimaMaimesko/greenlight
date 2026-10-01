#!/usr/bin/env bash
#
# Prove the template works end to end: scaffold a throwaway project, run its
# quality checks, apply and roll back its migrations on a real PostgreSQL,
# then exercise the API over HTTP.
#
#   verify.sh [--keep]
#
# Needs go, make, migrate (golang-migrate), psql, curl and jq, plus a
# PostgreSQL server reachable as a superuser through the usual libpq
# variables (PGHOST, PGPORT, PGUSER, PGPASSWORD); with none set, psql's own
# defaults apply. A uniquely named database and role are created and dropped
# afterwards. --keep leaves them and the project directory in place.
#
# Run it after every change to template/ or scripts/scaffold.sh.

set -uo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"

KEEP=0
case "${1:-}" in
--keep) KEEP=1 ;;
"") ;;
*)
	sed -n '3,15p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac

PASSED=0
FAILED=0

pass() {
	PASSED=$((PASSED + 1))
	printf '  ok    %s\n' "$1"
}

fail() {
	FAILED=$((FAILED + 1))
	printf '  FAIL  %s\n' "$1"
	if [ -n "${2:-}" ]; then printf '%s\n' "$2" | sed 's/^/        /'; fi
}

die() {
	echo "verify: $*" >&2
	exit 1
}

section() { printf '\n%s\n' "$1"; }

for tool in go gofmt make migrate psql curl jq; do
	command -v "$tool" >/dev/null 2>&1 || die "$tool is required but not installed"
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/go-api-skeleton-verify.XXXXXX")"
PROJECT="$WORK/project"
DB="skeleton_verify_$$"
PREFIX="SKELVERIFY"
PORT=$((20000 + $$ % 10000))
BASE="http://localhost:$PORT"
TRUSTED_ORIGIN="http://localhost:9999"
DB_HOST="${PGHOST:-localhost}"
case "$DB_HOST" in /*) DB_HOST=localhost ;; esac # a socket directory, not a host
DSN="postgres://$DB:pa55word@$DB_HOST:${PGPORT:-5432}/$DB?sslmode=disable"
API_PID=""
DB_CREATED=0

# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() {
	if [ -n "$API_PID" ]; then
		kill "$API_PID" 2>/dev/null
		wait "$API_PID" 2>/dev/null
	fi
	if [ "$KEEP" = 1 ]; then
		printf '\nkept project %s and database %s\n  %s\n' "$PROJECT" "$DB" "$DSN"
		return
	fi
	if [ "$DB_CREATED" = 1 ]; then
		# Close any connection still open (a backend can outlive its client
		# briefly), or DROP DATABASE refuses.
		if ! psql -q -v ON_ERROR_STOP=1 -d postgres \
			-c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB' AND pid <> pg_backend_pid()" \
			-c "DROP DATABASE IF EXISTS $DB" \
			-c "DROP ROLE IF EXISTS $DB" >"$WORK/out" 2>&1; then
			echo "verify: could not drop test database and role $DB; drop them by hand:" >&2
			cat "$WORK/out" >&2
		fi
	fi
	rm -rf "$WORK"
}
trap cleanup EXIT

# run DESC COMMAND... passes when the command exits 0, and shows the end of
# its output when it doesn't.
run() {
	local desc=$1
	shift
	if "$@" >"$WORK/out" 2>&1; then
		pass "$desc"
	else
		fail "$desc" "$(tail -15 "$WORK/out")"
	fi
}

# request METHOD PATH [JSON] calls the API, sending $TOKEN as a bearer token
# when it is set, and stores the response in STATUS, BODY and HEADERS.
TOKEN=""
request() {
	local args=(-s -X "$1" -o "$WORK/body" -D "$WORK/headers" -w '%{http_code}')
	if [ -n "$TOKEN" ]; then args+=(-H "Authorization: Bearer $TOKEN"); fi
	if [ $# -ge 3 ]; then args+=(-H "Content-Type: application/json" --data-raw "$3"); fi
	STATUS=$(curl "${args[@]}" "$BASE$2")
	BODY=$(cat "$WORK/body")
	HEADERS=$(tr -d '\r' <"$WORK/headers")
}

# expect DESC STATUS [JQ_FILTER] checks the last response's status code and,
# if given, that the jq filter is true for its body.
expect() {
	local desc=$1 want=$2 filter=${3:-}
	if [ "$STATUS" != "$want" ]; then
		fail "$desc" "want $want, got $STATUS: $BODY"
	elif [ -n "$filter" ] && ! jq -e "$filter" >/dev/null 2>&1 <<<"$BODY"; then
		fail "$desc" "jq '$filter' is not true for: $BODY"
	else
		pass "$desc"
	fi
}

# header NAME prints a header from the last response.
header() { printf '%s\n' "$HEADERS" | grep -i "^$1:" | head -1 | cut -d' ' -f2-; }

# sql STATEMENT runs SQL against the test database as the app's role.
sql() { psql -q -v ON_ERROR_STOP=1 "$DSN" -c "$1" >"$WORK/out" 2>&1 || fail "sql: $1" "$(cat "$WORK/out")"; }

start_api() {
	curl -s -o /dev/null "$BASE" && die "port $PORT is already in use"
	# SMTP on port 1 refuses connections at once, so background emails fail
	# fast instead of delaying shutdown.
	"$WORK/api" -port "$PORT" -smtp-host 127.0.0.1 -smtp-port 1 "$@" >"$WORK/api.log" 2>&1 &
	API_PID=$!
	for _ in $(seq 1 50); do
		curl -s -o /dev/null "$BASE/v1/healthcheck" && return 0
		sleep 0.2
	done
	die "the API did not start: $(cat "$WORK/api.log")"
}

stop_api() {
	local status
	kill -INT "$API_PID"
	wait "$API_PID"
	status=$?
	API_PID=""
	return "$status"
}

# ---------------------------------------------------------------------------
section "Scaffold"

run "scaffold with explicit names" "$SKILL_DIR/scripts/scaffold.sh" \
	--module example.org/verify/skeleton --dir "$PROJECT" \
	--name "Verify Skeleton" --prefix "$PREFIX" --db "$DB"
[ -f "$PROJECT/go.mod" ] || die "scaffolding failed, nothing else to check"

run "module path replaced" grep -q '^module example.org/verify/skeleton$' "$PROJECT/go.mod"
run "no placeholders left" bash -c "! grep -rn -E 'example\.com/app|APP_|localhost/app\?|# App API|App <no-reply|The App Team' '$PROJECT' --exclude=go.sum"
run "defaults derived from the module path" bash -c "
	'$SKILL_DIR/scripts/scaffold.sh' --module github.com/acme/book-store/v2 --dir '$WORK/defaults' >/dev/null &&
	grep -q '^BOOK_STORE_DB_DSN=postgres://book_store:pa55word@localhost/book_store?' '$WORK/defaults/.env.example' &&
	grep -q '^# Book Store API$' '$WORK/defaults/README.md' &&
	grep -q 'Welcome to Book Store!' '$WORK/defaults/internal/mailer/templates/user_welcome.tmpl'"
run "refuses a directory that isn't empty" bash -c "! '$SKILL_DIR/scripts/scaffold.sh' --module example.org/x --dir '$PROJECT'"
run "rejects unsafe names" bash -c "! '$SKILL_DIR/scripts/scaffold.sh' --module example.org/x --dir '$WORK/bad' --prefix 'X|Y'"

cd "$PROJECT" || die "cannot enter $PROJECT"

# ---------------------------------------------------------------------------
section "Quality checks"

# shellcheck disable=SC2016 # expanded by the inner bash
run "gofmt" bash -c '[ -z "$(gofmt -l .)" ]'
run "make audit (tidy, verify, vet, staticcheck, race tests)" make audit

# ---------------------------------------------------------------------------
section "Database and migrations"

psql -q -v ON_ERROR_STOP=1 -d postgres \
	-c "CREATE ROLE $DB WITH LOGIN PASSWORD 'pa55word'" \
	-c "CREATE DATABASE $DB OWNER $DB" >"$WORK/out" 2>&1 ||
	die "could not create the test database (is PostgreSQL running, and are PGHOST/PGUSER set to a superuser?): $(cat "$WORK/out")"
DB_CREATED=1
psql -q -v ON_ERROR_STOP=1 -d "$DB" -c "CREATE EXTENSION IF NOT EXISTS citext" >"$WORK/out" 2>&1 ||
	die "could not create the citext extension: $(cat "$WORK/out")"

# Point .env at the test database; make and the API both read it.
grep -v "^${PREFIX}_DB_DSN=" .env.example >.env
echo "${PREFIX}_DB_DSN=$DSN" >>.env

for f in migrations/*.up.sql; do last_migration=$f; done # globs sort, so this is the newest
LATEST=$(printf '%s' "${last_migration##*/}" | sed 's/^0*\([0-9][0-9]*\)_.*/\1/')
migration_version() { make -s db/migrations/version 2>&1 | tail -1; }

run "migrations up" bash -c 'echo y | make db/migrations/up'
run "at version $LATEST" test "$(migration_version)" = "$LATEST"
run "migrations down, every .down.sql" bash -c 'echo y | make db/migrations/down'
run "no version after down" bash -c '! make -s db/migrations/version'
run "migrations up again" bash -c 'echo y | make db/migrations/up'
run "at version $LATEST again" test "$(migration_version)" = "$LATEST"

# ---------------------------------------------------------------------------
section "Users and tokens"

go build -o "$WORK/api" ./cmd/api >"$WORK/out" 2>&1 || die "build failed: $(cat "$WORK/out")"
start_api -limiter-enabled=false -cors-trusted-origins "$TRUSTED_ORIGIN"

request GET /v1/healthcheck
expect "healthcheck" 200 '.status == "available" and .system_info.environment == "development"'

request POST /v1/users '{"name":"Alice","email":"alice@example.com","password":"pa55word1234"}'
expect "register" 202 '.user.activated == false and (.user | has("password") | not)'
request POST /v1/users '{"name":"Alice","email":"ALICE@example.com","password":"pa55word1234"}'
expect "duplicate email, case-insensitive" 422 '.error.email != null'
request POST /v1/users '{"name":"","email":"nope","password":"short"}'
expect "registration validation" 422 '.error | has("name") and has("email") and has("password")'

request PUT /v1/users/activated '{"token":"TOOSHORT"}'
expect "activation rejects a malformed token" 422 '.error.token != null'

# The real activation token only exists in the welcome email, so plant a
# known one, stored the same way the app stores tokens: as a SHA-256 hash.
ACTIVATION_TOKEN=VERIFYACTIVATIONTOKENABCDE
sql "INSERT INTO tokens (hash, user_id, expiry, scope)
     SELECT sha256('$ACTIVATION_TOKEN'::bytea), id, now() + interval '1 hour', 'activation'
     FROM users WHERE email = 'alice@example.com'"
request PUT /v1/users/activated "{\"token\":\"$ACTIVATION_TOKEN\"}"
expect "activate" 200 '.user.activated == true'
request PUT /v1/users/activated "{\"token\":\"$ACTIVATION_TOKEN\"}"
expect "activation token is single-use" 422

request POST /v1/users '{"name":"Bob","email":"bob@example.com","password":"pa55word1234"}'
request POST /v1/tokens/authentication '{"email":"bob@example.com","password":"pa55word1234"}'
TOKEN=$(jq -r '.authentication_token.token' <<<"$BODY")
request GET /v1/items
expect "inactive account is refused" 403
TOKEN=""

request GET /v1/items
expect "items need authentication" 401
request POST /v1/tokens/authentication '{"email":"alice@example.com","password":"wrong-password"}'
expect "login with a wrong password" 401
request POST /v1/tokens/authentication '{"email":"nobody@example.com","password":"pa55word1234"}'
expect "login with an unknown email" 401
request POST /v1/tokens/authentication '{"email":"alice@example.com","password":"pa55word1234"}'
expect "login" 201 '.authentication_token.token | length == 26'
TOKEN=$(jq -r '.authentication_token.token' <<<"$BODY")

# ---------------------------------------------------------------------------
section "Items"

request GET /v1/items
expect "list with the default items:read" 200 '.items == [] and .metadata == {}'
request POST /v1/items '{"name":"Widget"}'
expect "create without items:write" 403

sql "INSERT INTO users_permissions
     SELECT users.id, permissions.id FROM users, permissions
     WHERE users.email = 'alice@example.com' AND permissions.code = 'items:write'"

request POST /v1/items '{"name":"Blue widget","description":"Small and blue","tags":["blue","small"]}'
expect "create" 201 '.item.version == 1 and .item.tags == ["blue","small"]'
ID=$(jq -r '.item.id' <<<"$BODY")
run "Location header" test "$(header Location)" = "/v1/items/$ID"
request POST /v1/items '{"name":"Red gadget"}'
expect "create without tags" 201 '.item.tags == []'
request POST /v1/items '{"name":"Green widget","tags":null}'
expect "create with null tags" 201 '.item.tags == []'

request GET "/v1/items/$ID"
expect "show" 200 ".item.id == $ID and .item.name == \"Blue widget\""
request GET "/v1/items?name=widget&sort=-name"
expect "full-text search and descending sort" 200 '[.items[].name] == ["Green widget","Blue widget"] and .metadata.total_records == 2'
request GET "/v1/items?tags=blue,small"
expect "filter by tags" 200 '[.items[].name] == ["Blue widget"]'
request GET "/v1/items?page=2&page_size=2&sort=id"
expect "pagination" 200 '(.items | length) == 1 and .metadata.current_page == 2 and .metadata.last_page == 2 and .metadata.total_records == 3'

request PATCH "/v1/items/$ID" '{"description":"Updated"}'
expect "partial update keeps other fields" 200 '.item.description == "Updated" and .item.tags == ["blue","small"] and .item.version == 2'
request PATCH "/v1/items/$ID" '{"tags":[]}'
expect "update clears tags" 200 '.item.tags == [] and .item.version == 3'

request DELETE "/v1/items/$ID"
expect "delete" 200 '.message != null'
request GET "/v1/items/$ID"
expect "deleted item is gone" 404
request DELETE "/v1/items/$ID"
expect "delete twice" 404

# ---------------------------------------------------------------------------
section "Error responses"

request POST /v1/items '{"name":"","tags":["a","a","b","c","d","e"]}'
expect "item validation" 422 '.error | has("name") and has("tags")'
request POST /v1/items '{"name":"x","colour":"red"}'
expect "unknown JSON key" 400 '.error | test("unknown key")'
request POST /v1/items '{"name":'
expect "malformed JSON" 400 '.error | test("badly-formed")'
request POST /v1/items '{"name":"a"}{"name":"b"}'
expect "two JSON values" 400 '.error | test("single JSON value")'
request POST /v1/items '{"name":42}'
expect "wrong JSON type" 400 '.error | test("incorrect JSON type")'
request GET "/v1/items?sort=price&page=abc"
expect "bad query parameters" 422 '.error | has("sort") and has("page")'
request GET /v1/items/abc
expect "non-numeric id" 404
request GET /v1/nope
expect "unknown route, as JSON" 404 '.error != null'
request DELETE /v1/healthcheck
expect "wrong method, as JSON" 405 '.error != null'

TOKEN=AAAAAAAAAAAAAAAAAAAAAAAAAA
request GET /v1/items
expect "unknown token" 401
run "WWW-Authenticate header" test "$(header WWW-Authenticate)" = "Bearer"
TOKEN=""

# ---------------------------------------------------------------------------
section "CORS and metrics"

allow_origin() {
	curl -s -o /dev/null -D - "$@" | tr -d '\r' | grep -i '^access-control-allow-origin:' | cut -d' ' -f2-
}
run "trusted origin is allowed" test "$(allow_origin -H "Origin: $TRUSTED_ORIGIN" "$BASE/v1/healthcheck")" = "$TRUSTED_ORIGIN"
run "other origins are not" test -z "$(allow_origin -H "Origin: http://evil.example" "$BASE/v1/healthcheck")"
run "preflight request" bash -c "curl -s -o /dev/null -D - -X OPTIONS \
	-H 'Origin: $TRUSTED_ORIGIN' -H 'Access-Control-Request-Method: PATCH' '$BASE/v1/items/1' |
	tr -d '\r' | grep -qi '^access-control-allow-methods:.*PATCH'"

request GET /debug/vars
expect "expvar metrics" 200 '.total_requests_received > 0 and .database.MaxOpenConnections == 25 and .version != null'

# ---------------------------------------------------------------------------
section "Shutdown and rate limiting"

if stop_api; then pass "graceful shutdown exits 0"; else fail "graceful shutdown exits 0" "$(tail -5 "$WORK/api.log")"; fi
run "shutdown waited for background tasks" grep -q 'msg="shutdown complete"' "$WORK/api.log"
run "welcome emails were attempted in the background" grep -q 'level=ERROR.*127.0.0.1:1' "$WORK/api.log"

start_api -limiter-rps 1 -limiter-burst 2
codes=""
for _ in 1 2 3 4 5; do
	codes="$codes $(curl -s -o /dev/null -w '%{http_code}' "$BASE/v1/healthcheck")"
done
case "$codes" in
*429*) pass "rate limiter returns 429 (got$codes)" ;;
*) fail "rate limiter returns 429" "got$codes" ;;
esac
stop_api >/dev/null

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
if [ "$FAILED" -eq 0 ]; then exit 0; else exit 1; fi
