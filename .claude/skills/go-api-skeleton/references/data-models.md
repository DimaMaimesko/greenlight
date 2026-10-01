# Data layer (`internal/data`, `internal/validator`)

## One file per table

Each `internal/data/<resource>.go` holds three things:

1. The domain struct, with JSON tags.
2. `Validate<Resource>(v *validator.Validator, x X)`: the business rules.
3. `<Resource>Model struct { DB *sql.DB }` with the SQL methods.

`internal/data/items.go` is the complete example to copy. Register every
model in `internal/data/models.go`:

```go
type Models struct {
	Items       ItemModel
	Users       UserModel
	Tokens      TokenModel
	Permissions PermissionModel
}

func NewModels(db *sql.DB) Models {
	return Models{
		Items:       ItemModel{DB: db},
		...
	}
}
```

Handlers then call `app.models.Items.Get(id)`.

## Domain structs

```go
type Item struct {
	ID          int       `json:"id"`
	CreatedAt   time.Time `json:"created_at"`
	Name        string    `json:"name"`
	Description string    `json:"description,omitzero"`
	Tags        []string  `json:"tags"`
	Version     int       `json:"version"`
}
```

- Every field has an explicit snake_case JSON tag.
- `json:"-"` hides internal or sensitive fields: `User.Password`,
  `User.Version`, and everything on `Token` except the plaintext and expiry.
- Optional fields use `omitzero` (Go 1.24+), not `omitempty`.
- `ID int` maps to a `bigint` identity column.
- Every table that can be updated has `Version int`, for optimistic locking.

## Value semantics

This project differs from the book here: model methods take and return
**values**, not pointers.

```go
func (m ItemModel) Insert(item Item) (Item, error)
func (m ItemModel) Get(id int) (Item, error)
func (m ItemModel) Update(item Item) (Item, error)
func (m ItemModel) Delete(id int) error
func (m ItemModel) GetAll(name string, tags []string, filters Filters) ([]Item, Metadata, error)
```

- `Insert` and `Update` scan database-generated values (`id`, `created_at`,
  `version`) into their copy and return it. Callers reassign:
  `item, err = app.models.Items.Insert(item)`.
- On error, return the zero value (`Item{}`), never a half-filled struct.
- Model types use value receivers.

## Query rules

- Every query gets its own timeout:

  ```go
  ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
  defer cancel()
  ```

  and uses `QueryRowContext`, `QueryContext` or `ExecContext`, never the
  variants without a context.
- SQL goes in a raw string named `query` with `$1, $2...` placeholders; the
  values go in `args := []any{...}`.
- Use `RETURNING` to get generated values back in the same round trip.
- Postgres arrays: `pq.Array(x)` to write, `pq.Array(&x)` to scan.
  `pq.Array` writes a nil slice as NULL, so for a `NOT NULL` array column
  the model turns nil into `[]string{}` before writing (see
  `ItemModel.Insert`).
- Skip the query for impossible IDs: `if id < 1 { return Item{}, ErrRecordNotFound }`.
- Lists: `defer rows.Close()`, check `rows.Err()` after the loop, and start
  with `items := []Item{}` so an empty result encodes as `[]`, not `null`.

## Errors

Shared sentinel errors live in `models.go` (`ErrRecordNotFound`,
`ErrEditConflict`); resource-specific ones sit next to their model
(`ErrDuplicateEmail` in `users.go`). Translate driver errors inside the
model, so handlers never see `database/sql` or `pq` types:

| Driver result | Model returns |
| --- | --- |
| `sql.ErrNoRows` from a lookup | `ErrRecordNotFound` |
| `sql.ErrNoRows` from a versioned `UPDATE` | `ErrEditConflict` |
| `RowsAffected() == 0` from a `DELETE` | `ErrRecordNotFound` |
| `*pq.Error` with code `23505` on constraint `users_email_key` | `ErrDuplicateEmail` |
| anything else | the error unchanged (the handler sends a 500) |

Models never log.

## Optimistic locking

```sql
UPDATE items
SET name = $1, description = $2, tags = $3, version = version + 1
WHERE id = $4 AND version = $5
RETURNING version
```

No row back means someone changed the record after it was read, so the model
returns `ErrEditConflict` and the handler sends 409. The client re-reads and
retries.

## Lists, filtering and pagination (`filters.go`, `ItemModel.GetAll`)

- `Filters{Page, PageSize, Sort, SortSafelist}`. `ValidateFilters` allows page
  1 to 10,000,000, page_size 1 to 100, and only safelisted sort values.
- `ORDER BY` can't take a placeholder, so the column is inserted with
  `fmt.Sprintf`, but only through `sortColumn()`, which panics if the value
  isn't safelisted (a second defence after validation). Always add `, id ASC`
  as a tiebreaker so pages are stable.
- `LIMIT $3 OFFSET $4` come from `filters.limit()` and `filters.offset()`.
- `count(*) OVER()` returns the total match count on every row, so one query
  gives both the page and the total. `calculateMetadata` turns it into
  `Metadata` (current, first and last page, total), and returns an empty
  `Metadata` when nothing matched.
- Optional filters stay in one static query that matches everything when the
  parameter is empty:

  ```sql
  WHERE (to_tsvector('simple', name) @@ plainto_tsquery('simple', $1) OR $1 = '')
  AND (tags @> $2 OR $2 = '{}')
  ```

## Validation (`internal/validator`)

- `validator.New()` gives `Errors map[string]string`. `Check(ok, key, message)`
  keeps only the first failure per key; `Valid()` reports whether any exist.
- Helpers: `PermittedValue[T]`, `Matches(value, rx)`, `Unique[T]`, `EmailRX`.
  The package knows nothing about the domain.
- Domain rules live in `internal/data` as `Validate<Thing>` functions, so
  every caller shares them. They compose: `ValidateUser` calls `ValidateEmail`
  and `ValidatePasswordPlaintext`, and the login handler calls those two
  directly.
- Messages are lowercase and read after the field name: `must be provided`,
  `must not be more than 500 bytes long`.
- Back important rules with a database `CHECK` constraint as well
  (migrations.md): validation gives good messages, constraints keep the data
  correct no matter who writes it.
- Programmer errors panic. `ValidateUser` panics if the password hash is nil,
  because that can only mean `Password.Set` was never called.
