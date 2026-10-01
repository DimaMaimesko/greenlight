# Tests

Write table-driven tests for the logic you add, by default, without waiting
to be asked. Validation rules and parsers are where the edge cases live (the
501st byte, the sixth tag, `"12.345"` as a price), they need no database, they
run in milliseconds, and `make audit` runs them on every check.

## What gets a test by default

- Every new or changed `Validate<Thing>` function in `internal/data`.
- Every parser or custom type: an `UnmarshalJSON` / `MarshalJSON` pair, a
  `Price` that reads `"12.99"` into cents, an ISBN check digit, a slug or
  date format.
- Pure helpers with branches: sort safelists, pagination maths, anything that
  turns input into a decision without touching the database.

Handler and SQL tests need a running PostgreSQL and test data. Offer them
rather than adding them unasked; if the user wants them, use
`net/http/httptest`, read the database DSN from a `TEST_DATABASE_URL`
variable, and `t.Skip` when it is unset so `make audit` still passes on a
machine without a database.

## Where and how

- Next to the code: `internal/data/books.go` gets
  `internal/data/books_test.go`, in the same package (`package data`), so
  unexported helpers can be tested too.
- Standard `testing` package only. No assertion or mocking library: a failed
  check is `t.Errorf` with what was wanted and what was got.
- One table per function: a slice of cases, each with a `name`, the input and
  the expected result, run with `t.Run(tt.name, ...)` so a failure names the
  case.
- Cover the valid case, both sides of every limit (500 bytes passes, 501
  fails), and each rule on its own so one failing rule can't hide another.
- For validators, check which field failed, not the message text: messages
  get reworded, field keys are part of the API.
- Rules that depend on the clock (no future years) compute their boundary in
  the test from `time.Now()` rather than hard-coding a year.

## A validator

```go
package data

import (
	"strings"
	"testing"

	"example.com/app/internal/validator"
)

func TestValidateItem(t *testing.T) {
	tests := []struct {
		name      string
		item      Item
		wantField string // the field expected to fail; "" means valid
	}{
		{name: "valid", item: Item{Name: "Widget", Tags: []string{"blue"}}},
		{name: "no tags", item: Item{Name: "Widget"}},
		{name: "missing name", item: Item{}, wantField: "name"},
		{name: "name at the limit", item: Item{Name: strings.Repeat("a", 500)}},
		{name: "name over the limit", item: Item{Name: strings.Repeat("a", 501)}, wantField: "name"},
		{name: "six tags", item: Item{Name: "x", Tags: []string{"a", "b", "c", "d", "e", "f"}}, wantField: "tags"},
		{name: "duplicate tags", item: Item{Name: "x", Tags: []string{"a", "a"}}, wantField: "tags"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			v := validator.New()
			ValidateItem(v, tt.item)

			if tt.wantField == "" {
				if !v.Valid() {
					t.Errorf("want valid, got %v", v.Errors)
				}
				return
			}

			if _, ok := v.Errors[tt.wantField]; !ok {
				t.Errorf("want an error for %q, got %v", tt.wantField, v.Errors)
			}
		})
	}
}
```

## A parser

For a custom JSON type, test the raw JSON in, the value out, and the inputs
that must be rejected. With the `Runtime` type from handlers.md:

```go
func TestRuntimeUnmarshalJSON(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		want    Runtime
		wantErr bool
	}{
		{name: "valid", input: `"102 mins"`, want: 102},
		{name: "not quoted", input: `102`, wantErr: true},
		{name: "wrong unit", input: `"102 minutes"`, wantErr: true},
		{name: "not a number", input: `"abc mins"`, wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var got Runtime
			err := got.UnmarshalJSON([]byte(tt.input))

			if tt.wantErr {
				if err == nil {
					t.Errorf("want an error, got %d", got)
				}
				return
			}

			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tt.want {
				t.Errorf("got %d, want %d", got, tt.want)
			}
		})
	}
}
```

When a type has both directions, add a round-trip case: marshal a value,
unmarshal the result, and check you get the same value back.

## Running them

`go test ./...` for a quick run; `make audit` runs them with the race
detector alongside vet and staticcheck, and both must pass before the work is
done.
