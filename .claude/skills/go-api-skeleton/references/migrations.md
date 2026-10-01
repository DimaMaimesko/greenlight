# Database and migrations

PostgreSQL through `database/sql` and `lib/pq`. The schema is changed only by
plain SQL migrations run with the
[golang-migrate](https://github.com/golang-migrate/migrate) CLI.

## Commands (Makefile)

| Command | Does |
| --- | --- |
| `make db/migrations/new name=create_reviews_table` | creates the next numbered `.up.sql` / `.down.sql` pair |
| `make db/migrations/up` | applies everything pending (asks first) |
| `make db/migrations/version` | prints the current version |
| `make db/migrations/rollback` | undoes the last migration (asks first) |
| `make db/migrations/goto version=3` | moves up or down to a version (asks first) |
| `make db/migrations/down` | undoes everything (asks first) |
| `make db/psql` | opens psql on the project database |

All of them use `APP_DB_DSN` (the project's own prefix after scaffolding)
from the environment or `.env`.

## Files

- `migrations/00000N_<what>.up.sql` and the matching `.down.sql`, created by
  `migrate create -seq -ext=.sql`. Names are snake_case descriptions. The
  template ships:

  ```
  000001_create_users_table
  000002_create_tokens_table
  000003_create_permissions_tables
  000004_create_items_table
  000005_add_items_check_constraints
  000006_add_items_indexes
  000007_add_items_permissions
  ```

- One concern per migration: create the table, then its constraints, then its
  indexes, then its permission codes, each in its own pair.
- `down` undoes exactly what `up` did, in reverse order.
- Use `IF NOT EXISTS` / `IF EXISTS` so re-running after a failure doesn't trip
  over objects that were already created.
- **Never edit a migration that has been applied anywhere.** Add a new one.

## Table conventions

```sql
CREATE TABLE IF NOT EXISTS items (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    created_at timestamp(0) with time zone NOT NULL DEFAULT NOW(),
    name text NOT NULL,
    description text NOT NULL DEFAULT '',
    tags text[] NOT NULL DEFAULT '{}',
    version integer NOT NULL DEFAULT 1
);
```

- `id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY`, not `serial`.
- `created_at timestamp(0) with time zone NOT NULL DEFAULT NOW()`.
- `version integer NOT NULL DEFAULT 1` on any table that gets updated.
- Every column `NOT NULL` unless there is a real reason for NULL. Optional
  values get a default (`''`, `'{}'`); Go zero values and `omitzero` handle
  "not set".
- `text`, not `varchar(n)`; limit lengths in validation and a CHECK.
- `citext` for values compared case-insensitively, such as email.
- `bytea` for hashes.
- Foreign keys: `user_id bigint NOT NULL REFERENCES users ON DELETE CASCADE`.
- Join tables use a composite primary key:
  `PRIMARY KEY (user_id, permission_id)`.
- Lookup codes are `UNIQUE` (`permissions.code`).

## Constraints and indexes

- Mirror the Go validation rules that protect data integrity with named
  `CHECK` constraints. Go's `len()` counts bytes, so compare with
  `octet_length()`, not `length()`, which counts characters:

  ```sql
  ALTER TABLE items ADD CONSTRAINT items_name_length_check CHECK (octet_length(name) BETWEEN 1 AND 500);
  ALTER TABLE items ADD CONSTRAINT items_description_length_check CHECK (octet_length(description) <= 5000);
  ALTER TABLE items ADD CONSTRAINT items_tags_length_check CHECK (cardinality(tags) <= 5);
  ```

- Index what the queries filter on. GIN indexes for full-text search and
  array containment:

  ```sql
  CREATE INDEX IF NOT EXISTS items_name_idx ON items USING GIN (to_tsvector('simple', name));
  CREATE INDEX IF NOT EXISTS items_tags_idx ON items USING GIN (tags);
  ```

- Constraint names matter when Go code checks for them: `UserModel.Insert`
  maps the unique violation on `users_email_key` to `ErrDuplicateEmail`.

## Seed data

Reference data the code depends on gets its own migration, with a down
migration that removes exactly those rows. The permission codes for items
(`000007_add_items_permissions`):

```sql
-- up
INSERT INTO permissions (code)
VALUES
    ('items:read'),
    ('items:write');

-- down
DELETE FROM permissions WHERE code IN ('items:read', 'items:write');
```

Test or demo data does not belong in migrations.

## Database setup

The app's role owns its database but is not a superuser, so extensions are
created once by a superuser before the first migration:

```bash
psql postgres -c "CREATE ROLE app WITH LOGIN PASSWORD 'pa55word';"
psql postgres -c "CREATE DATABASE app OWNER app;"
psql app -c "CREATE EXTENSION IF NOT EXISTS citext;"
```

## Connection pool (`openDB` in `cmd/api/main.go`)

- `SetMaxOpenConns` (default 25), `SetMaxIdleConns` (25),
  `SetConnMaxIdleTime` (15m), all set by flags.
- `PingContext` with a 5-second timeout at startup; on failure close the pool
  and return the error.
- The pool's `Stats()` are published to expvar as `database`.
