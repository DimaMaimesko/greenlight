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

All of them use `GREENLIGHT_DB_DSN` from the environment or `.env`.

## Files

- `migrations/00000N_<what>.up.sql` and the matching `.down.sql`, created by
  `migrate create -seq -ext=.sql`. Names are snake_case descriptions:
  `create_movies_table`, `add_movies_check_constraints`, `add_movies_indexes`,
  `add_permissions`.
- One concern per migration: create the table, then its constraints, then its
  indexes, each in its own pair.
- `down` undoes exactly what `up` did, in reverse order.
- Use `IF NOT EXISTS` / `IF EXISTS` so a partly applied migration can be
  re-run.
- **Never edit a migration that has been applied anywhere.** Add a new one.

## Table conventions

```sql
CREATE TABLE IF NOT EXISTS movies (
    id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY,
    created_at timestamp(0) with time zone NOT NULL DEFAULT NOW(),
    title text NOT NULL,
    year integer NOT NULL,
    runtime integer NOT NULL,
    genres text[] NOT NULL,
    version integer NOT NULL DEFAULT 1
);
```

- `id bigint PRIMARY KEY GENERATED ALWAYS AS IDENTITY`, not `serial`.
- `created_at timestamp(0) with time zone NOT NULL DEFAULT NOW()`.
- `version integer NOT NULL DEFAULT 1` on any table that gets updated.
- Every column `NOT NULL` unless there is a real reason for NULL; Go
  zero values and `omitzero` handle "not set".
- `text`, not `varchar(n)`; limit lengths in validation (and a CHECK if it
  matters).
- `citext` for values compared case-insensitively, such as email.
- `bytea` for hashes.
- Foreign keys: `user_id bigint NOT NULL REFERENCES users ON DELETE CASCADE`.
- Join tables use a composite primary key:
  `PRIMARY KEY (user_id, permission_id)`.

## Constraints and indexes

- Mirror the Go validation rules that protect data integrity with named
  `CHECK` constraints:

  ```sql
  ALTER TABLE movies ADD CONSTRAINT movies_runtime_check CHECK (runtime >= 0);
  ALTER TABLE movies ADD CONSTRAINT movies_year_check CHECK (year BETWEEN 1888 AND date_part('year', now()));
  ALTER TABLE movies ADD CONSTRAINT genres_length_check CHECK (array_length(genres, 1) BETWEEN 1 AND 5);
  ```

- Index what the queries filter on. GIN indexes for full-text search and
  array containment:

  ```sql
  CREATE INDEX IF NOT EXISTS movies_title_idx ON movies USING GIN (to_tsvector('simple', title));
  CREATE INDEX IF NOT EXISTS movies_genres_idx ON movies USING GIN (genres);
  ```

- Constraint names matter when Go code checks for them: `UserModel.Insert`
  maps the unique violation on `users_email_key` to `ErrDuplicateEmail`.

## Seed data

Reference data the code depends on is inserted by the same migration that
creates its table, e.g. the permission codes in `000006_add_permissions.up.sql`:

```sql
INSERT INTO permissions (code)
VALUES
    ('movies:read'),
    ('movies:write');
```

Test or demo data does not belong in migrations.

## Database setup

The app's role owns its database but is not a superuser, so extensions are
created once by a superuser before the first migration:

```bash
psql postgres -c "CREATE ROLE greenlight WITH LOGIN PASSWORD 'pa55word';"
psql postgres -c "CREATE DATABASE greenlight OWNER greenlight;"
psql greenlight -c "CREATE EXTENSION IF NOT EXISTS citext;"
```

## Connection pool (`openDB` in `cmd/api/main.go`)

- `SetMaxOpenConns` (default 25), `SetMaxIdleConns` (25),
  `SetConnMaxIdleTime` (15m), all set by flags.
- `PingContext` with a 5-second timeout at startup; on failure close the pool
  and return the error.
- The pool's `Stats()` are published to expvar as `database`.
