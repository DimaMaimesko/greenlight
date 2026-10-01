#!/usr/bin/env bash
#
# Create a new Go JSON API project from the go-api-skeleton template.
#
#   scaffold.sh --module github.com/acme/bookstore [--dir ./bookstore]
#               [--name "Bookstore"] [--prefix BOOKSTORE] [--db bookstore]
#
# Only --module is required. The others are derived from the last element of
# the module path (a trailing /vN is skipped):
#
#   --dir     ./<last element>             where to create the project
#   --db      book-store -> book_store     PostgreSQL database and role name
#   --prefix  book_store -> BOOK_STORE     environment variable prefix
#   --name    book-store -> Book Store     display name in emails and README
#
# The script copies files and renames; it needs no network access. It works
# with the bash 3.2 and BSD tools that ship with macOS.

set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "$0")/../template" && pwd)"

usage() {
	sed -n '3,17p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
}

die() {
	echo "scaffold: $*" >&2
	exit 1
}

module="" dir="" name="" prefix="" db=""

while [ $# -gt 0 ]; do
	case "$1" in
	--module) module="${2:-}"; shift 2 ;;
	--dir) dir="${2:-}"; shift 2 ;;
	--name) name="${2:-}"; shift 2 ;;
	--prefix) prefix="${2:-}"; shift 2 ;;
	--db) db="${2:-}"; shift 2 ;;
	-h | --help) usage ;;
	*) die "unknown argument: $1 (see --help)" ;;
	esac
done

[ -n "$module" ] || usage

# Derive defaults from the module path's last element, skipping a major
# version suffix such as /v2.
base="${module##*/}"
if [[ "$base" =~ ^v[0-9]+$ ]]; then
	trimmed="${module%/*}"
	base="${trimmed##*/}"
fi

[ -n "$db" ] || db="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')"
[ -n "$prefix" ] || prefix="$(printf '%s' "$db" | tr '[:lower:]' '[:upper:]')"
[ -n "$name" ] || name="$(printf '%s' "$base" | awk -F'[-_.]' '{
	for (i = 1; i <= NF; i++) printf "%s%s", (i > 1 ? " " : ""), toupper(substr($i, 1, 1)) substr($i, 2)
}')"
[ -n "$dir" ] || dir="./$base"

# Validate everything before touching the filesystem. These patterns also
# guarantee the values are safe inside the sed replacements below.
[[ "$module" =~ ^[A-Za-z0-9][A-Za-z0-9._~/-]*$ ]] || die "invalid --module: $module"
[[ "$db" =~ ^[a-z_][a-z0-9_]*$ ]] || die "invalid --db: $db (lowercase letters, digits and _, not starting with a digit)"
[[ "$prefix" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "invalid --prefix: $prefix (uppercase letters, digits and _)"
[[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9\ .-]*$ ]] || die "invalid --name: $name (letters, digits, spaces, . and -)"

if [ -e "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
	die "$dir already exists and is not empty"
fi

mkdir -p "$dir"
cp -R "$TEMPLATE_DIR/." "$dir/"
cd "$dir"

# replace FILE PATTERN REPLACEMENT applies a sed substitution to one file
# without sed -i, whose arguments differ between GNU and BSD sed.
replace() {
	sed "s|$2|$3|g" "$1" >"$1.tmp" && mv "$1.tmp" "$1"
}

# Go module path.
for f in go.mod $(find . -name '*.go'); do
	replace "$f" 'example\.com/app' "$module"
done

# Environment variable prefix.
for f in .env.example Makefile README.md cmd/api/main.go; do
	replace "$f" 'APP_' "${prefix}_"
done

# Database and role name.
for f in .env.example Makefile; do
	replace "$f" '//app:pa55word@localhost/app?' "//${db}:pa55word@localhost/${db}?"
done
replace README.md 'CREATE ROLE app WITH' "CREATE ROLE ${db} WITH"
replace README.md 'CREATE DATABASE app OWNER app;' "CREATE DATABASE ${db} OWNER ${db};"
replace README.md 'psql app -c' "psql ${db} -c"

# Display name.
replace README.md '^# App API' "# ${name} API"
for f in README.md .env.example cmd/api/main.go; do
	replace "$f" 'App <no-reply@' "${name} <no-reply@"
done
tmpl=internal/mailer/templates/user_welcome.tmpl
replace "$tmpl" 'Welcome to App!' "Welcome to ${name}!"
replace "$tmpl" 'signing up to App\.' "signing up to ${name}."
replace "$tmpl" 'The App Team' "The ${name} Team"

# A new module path can sort differently from example.com among the other
# imports, so let gofmt put them back in order. gofmt ships with Go and works
# offline.
if command -v gofmt >/dev/null 2>&1; then
	gofmt -w .
else
	echo "scaffold: gofmt not found; run 'make tidy' once Go is installed" >&2
fi

# Fail loudly if a placeholder survived, e.g. because the template changed
# and this script wasn't updated to match. A check is skipped when the chosen
# value happens to equal the placeholder.
leftovers=""
check_gone() {
	local hits
	hits="$(grep -rn -- "$1" . 2>/dev/null | grep -v '^\./go\.sum:' || true)"
	[ -z "$hits" ] || leftovers="${leftovers}${hits}"$'\n'
}
[ "$module" = "example.com/app" ] || check_gone 'example\.com/app'
[ "$prefix" = "APP" ] || check_gone 'APP_'
[ "$db" = "app" ] || { check_gone 'localhost/app?'; check_gone 'ROLE app '; check_gone 'psql app '; }
[ "$name" = "App" ] || { check_gone '# App API'; check_gone 'App <no-reply'; check_gone 'to App[!.]'; check_gone 'The App Team'; }
[ -z "$leftovers" ] || die "placeholders left after renaming:
$leftovers"

cat <<EOF
Created $dir
  module:      $module
  name:        $name
  env prefix:  ${prefix}_
  database:    $db (role $db, password pa55word)

Next steps (see README.md):
  cd $dir
  psql postgres -c "CREATE ROLE $db WITH LOGIN PASSWORD 'pa55word';"
  psql postgres -c "CREATE DATABASE $db OWNER $db;"
  psql $db -c "CREATE EXTENSION IF NOT EXISTS citext;"
  cp .env.example .env
  make db/migrations/up
  make run/api
EOF
