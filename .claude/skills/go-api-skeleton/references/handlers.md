# Handlers, JSON and error responses

Everything here lives in `cmd/api`. Read `helpers.go` and `errors.go` before
writing a handler: they are short and every handler uses them.

## Handler anatomy

Every handler that takes a body follows the same steps. From
`createItemHandler` in `cmd/api/items.go`:

```go
func (app *application) createItemHandler(w http.ResponseWriter, r *http.Request) {
	// 1. An anonymous input struct holding only the fields a client may send.
	var input struct {
		Name        string   `json:"name"`
		Description string   `json:"description"`
		Tags        []string `json:"tags"`
	}

	// 2. Decode. Any error here is the client's fault: 400.
	err := app.readJSON(w, r, &input)
	if err != nil {
		app.badRequestResponse(w, r, err)
		return
	}

	// 3. Copy into the domain struct. Never decode straight into it, or
	//    clients could set ID, Version or CreatedAt.
	item := data.Item{
		Name:        input.Name,
		Description: input.Description,
		Tags:        input.Tags,
	}

	// 4. Validate: 422 with a field -> message map.
	v := validator.New()

	if data.ValidateItem(v, item); !v.Valid() {
		app.failedValidationResponse(w, r, v.Errors)
		return
	}

	// 5. Call the model. Map known errors; anything else is a 500.
	item, err = app.models.Items.Insert(item)
	if err != nil {
		app.serverErrorResponse(w, r, err)
		return
	}

	// 6. Respond inside an envelope.
	headers := make(http.Header)
	headers.Set("Location", fmt.Sprintf("/v1/items/%d", item.ID))

	err = app.writeJSON(w, http.StatusCreated, envelope{"item": item}, headers)
	if err != nil {
		app.serverErrorResponse(w, r, err)
	}
}
```

- `return` after every error response. The final `writeJSON` error check
  needs none because it is the last statement.
- Handlers don't log. The error helpers do.

## Status codes

| Situation | Status | Example |
| --- | --- | --- |
| Read, update or delete succeeded | 200 | `showItemHandler`, `updateItemHandler`, `deleteItemHandler` |
| Created | 201, plus `Location` when the resource has a URL | `createItemHandler`, `createAuthenticationTokenHandler` |
| Accepted, work continues in the background | 202 | `registerUserHandler` (welcome email) |
| Malformed body or query | 400 | `badRequestResponse` |
| No, invalid or expired credentials | 401 | `authenticationRequiredResponse`, `invalidCredentialsResponse`, `invalidAuthenticationTokenResponse` |
| Authenticated but not allowed | 403 | `inactiveAccountResponse`, `missingPermissionResponse` |
| Missing resource, or an `:id` that isn't a positive integer | 404 | `notFoundResponse` |
| Wrong method | 405 | `methodNotAllowedResponse` (set on the router) |
| Version conflict | 409 | `editConflictResponse` |
| Validation failed | 422 | `failedValidationResponse` |
| Rate limited | 429 | `rateLimitExceededResponse` |
| Anything unexpected | 500 | `serverErrorResponse` |

A delete returns 200 with `envelope{"message": "item successfully deleted"}`.

## The envelope and `writeJSON` (`cmd/api/helpers.go`)

- `type envelope map[string]any`. Every response is an object with a named
  top-level key: `{"item": ...}`, `{"items": [...], "metadata": {...}}`,
  `{"error": ...}`. Never a bare array or value; the key makes responses
  self-describing and leaves room to add fields.
- `writeJSON(w, status, data envelope, headers http.Header) error` marshals
  first (so a failure can still become a clean 500), indents with tabs and
  adds a trailing newline (readable in curl, the extra bytes don't matter),
  copies `headers`, sets `Content-Type: application/json`, then writes.

## `readJSON` (`cmd/api/helpers.go`)

`readJSON(w, r, dst any) error` is the only way to read a request body.

- `http.MaxBytesReader` caps the body at 1MB.
- `DisallowUnknownFields`: an unknown key is an error, not silently dropped.
- Decoder errors become messages that are safe to send to the client: badly
  formed JSON (with the character offset), wrong type for a field, empty body,
  unknown key, body too large.
- `*json.InvalidUnmarshalError` means a non-pointer was passed: a programmer
  error, so it panics and `recoverPanic` turns it into a 500.
- A second `Decode` must return `io.EOF`, so the body holds exactly one JSON
  value.
- Errors from a custom `UnmarshalJSON` come through unchanged, so the client
  gets that error's message with a 400 (see Custom JSON types below).

## Partial updates (`updateItemHandler`)

1. `readIDParam`; on error, `notFoundResponse`.
2. Fetch the current record; `ErrRecordNotFound` → 404.
3. Decode into an input struct with **pointer fields** (`*string`, `*int`),
   so a missing key (nil) differs from a zero value. Slices and maps are
   already nil when missing; a client clears `tags` by sending `[]`.
4. Copy only non-nil fields onto the record.
5. Validate the whole merged record.
6. `Update`; `ErrEditConflict` → 409.

Use `PATCH` for partial updates. `PUT` is for idempotent "set this state"
actions such as `PUT /v1/users/activated`.

## URL parameters

`readIDParam(r) (int, error)` reads `:id` via `httprouter.ParamsFromContext`
and rejects anything that isn't an integer ≥ 1. Handlers answer 404, not 400:
an ID that can't exist is just a resource that doesn't exist.

## Query strings (`listItemsHandler`)

- `qs := r.URL.Query()`, then `readString(qs, key, default)`,
  `readCSV(qs, key, default)` and `readInt(qs, key, default, v)`. `readInt`
  records `must be an integer value` on the validator instead of failing, so
  every bad parameter is reported at once.
- The input struct embeds `data.Filters`. Set the defaults (page 1, page_size
  20, sort `id`) and a `SortSafelist` that lists each sortable column and its
  `-` (descending) form: `id`, `name`, `created_at`, `-id`, `-name`,
  `-created_at`.
- `data.ValidateFilters(v, input.Filters)` → 422 on failure.
- Respond with `envelope{"items": items, "metadata": metadata}`.

## Error responses (`cmd/api/errors.go`)

- `errorResponse(w, r, status, message any)` writes `{"error": message}`.
  `message` is `any` so validation can send a `map[string]string`.
- `serverErrorResponse` logs the real error through `logError` (which adds
  `method` and `uri`) and sends a generic message. Never send the text of an
  unexpected error to the client.
- One named helper per situation, each with a fixed message. To add a new
  error case, add a helper here; don't call `errorResponse` with ad-hoc text
  from a handler.
- `routes()` sets `router.NotFound` and `router.MethodNotAllowed` to these
  helpers, so routing errors are JSON too.

## Mapping model errors

```go
item, err := app.models.Items.Get(id)
if err != nil {
	switch {
	case errors.Is(err, data.ErrRecordNotFound):
		app.notFoundResponse(w, r)
	default:
		app.serverErrorResponse(w, r, err)
	}
	return
}
```

Some data errors are really validation failures and become a field error:
`registerUserHandler` turns `data.ErrDuplicateEmail` into
`v.AddError("email", "a user with this email address already exists")` → 422.

## Background work

Never use a bare `go` statement in a handler. Use `app.background(fn)`
(`cmd/api/helpers.go`): it runs `fn` with `app.wg.Go` so graceful shutdown
waits for it, and recovers panics, which `recoverPanic` can't do for other
goroutines. Inside the closure:

- Use only values copied beforehand (`user.Email`, `token.Plaintext`), never
  `r` or `w`; the response is already sent.
- Log errors there with `app.logger.Error`; nobody is waiting for them.

Example: the welcome email in `registerUserHandler`.

## Custom JSON types

To control how a field looks in JSON, give it its own type in `internal/data`
with `MarshalJSON` (value receiver) and `UnmarshalJSON` (pointer receiver).
The book's example stores a runtime as minutes and shows it as `"134 mins"`:

```go
type Runtime int

var ErrInvalidRuntimeFormat = errors.New("invalid runtime format")

func (r Runtime) MarshalJSON() ([]byte, error) {
	return []byte(strconv.Quote(fmt.Sprintf("%d mins", r))), nil
}

func (r *Runtime) UnmarshalJSON(jsonValue []byte) error {
	unquoted, err := strconv.Unquote(string(jsonValue))
	if err != nil {
		return ErrInvalidRuntimeFormat
	}

	parts := strings.Split(unquoted, " ")
	if len(parts) != 2 || parts[1] != "mins" {
		return ErrInvalidRuntimeFormat
	}

	i, err := strconv.Atoi(parts[0])
	if err != nil {
		return ErrInvalidRuntimeFormat
	}

	*r = Runtime(i)
	return nil
}
```

A field of this type rejects `"134 minutes"` with 400 `invalid runtime format`.
In an update input struct use a pointer to it (`*data.Runtime`).
