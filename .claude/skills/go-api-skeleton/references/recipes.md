# Recipes

Step-by-step checklists for common changes. Each step names the file to
touch; the other references explain the rules for each layer. Finish every
recipe with `make tidy` and `make audit`.

## Add a resource (e.g. `reviews`)

1. **Migrations** (migrations.md)
   - `make db/migrations/new name=create_reviews_table`: table with `id`,
     `created_at`, the columns, `version`.
   - If needed: `add_reviews_check_constraints`, `add_reviews_indexes`.
   - If the resource gets its own permissions, a migration inserting
     `reviews:read` and `reviews:write` into `permissions`.
   - `make db/migrations/up`.
2. **Model**: `internal/data/reviews.go` (data-models.md)
   - `type Review struct` with JSON tags and `Version int`.
   - `func ValidateReview(v *validator.Validator, review Review)`.
   - `type ReviewModel struct { DB *sql.DB }` with `Insert`, `Get`, `Update`
     (version check), `Delete`, and `GetAll(..., filters Filters)` if it can be
     listed. Values in, values out; a 3-second timeout per query; driver errors
     translated to `ErrRecordNotFound` / `ErrEditConflict`.
3. **Register** the model: add `Reviews ReviewModel` to `Models` and
   `Reviews: ReviewModel{DB: db}` to `NewModels` in `internal/data/models.go`.
4. **Handlers**: `cmd/api/reviews.go` (handlers.md)
   - `createReviewHandler` (201 + `Location`), `showReviewHandler`,
     `updateReviewHandler` (PATCH, pointer input fields, 409 on conflict),
     `deleteReviewHandler`, `listReviewsHandler` (filters + metadata).
5. **Routes**: `cmd/api/routes.go`
   - `/v1/reviews` and `/v1/reviews/:id`, each wrapped in
     `app.requireActivatedUserWithPermission("reviews:read", ...)` or
     `"reviews:write"`.
6. **Default permissions**: if new users should get `reviews:read`, add it to
   the `Permissions.AddForUser` call in `registerUserHandler`.
7. **Docs**: add the endpoints to `docs/openapi.yaml` and the README, if the
   project has them.
8. **Check**: `make audit`, then exercise each endpoint with curl, including
   the 404, 409 and 422 paths.

A resource that belongs to a user (only the owner may edit it) adds a
`user_id` foreign key, sets it from `app.contextGetAuthenticatedUser(r)` on
create, and filters or checks on it in the model's queries.

## Add a field to an existing resource

1. New migration: `ALTER TABLE ... ADD COLUMN ... NOT NULL DEFAULT ...` (and a
   `CHECK` if it has rules). Never edit the original migration.
2. Add the field to the struct, `Validate<Resource>`, and every query's
   column list and `Scan` call in the model.
3. Add it to the create handler's input struct, and as a pointer to the update
   handler's input struct.
4. Add it to `SortSafelist` if it should be sortable.

## Add an error response

Add a method to `cmd/api/errors.go` that calls `errorResponse` with the status
code and a fixed lowercase message, then call it from handlers or middleware:

```go
func (app *application) <situation>Response(w http.ResponseWriter, r *http.Request) {
	message := "..."
	app.errorResponse(w, r, http.Status..., message)
}
```

## Add a middleware

1. Write it in `cmd/api/middleware.go` as
   `func (app *application) name(next http.Handler) http.Handler`
   (middleware.md).
2. Applies to every request: place it in the chain at the end of `routes()`,
   in the position that fits what it needs to see.
3. Applies to some routes: write it as
   `func (app *application) name(next http.HandlerFunc) http.HandlerFunc`
   and wrap those routes.
4. If it puts something in the request context, add a key and get/set helpers
   to `cmd/api/context.go`.

## Add a config setting

See the checklist at the end of config.md: `config` field, flag with
environment default, required check, `.env.example`, README table.

## Send a new email

1. Create `internal/mailer/templates/<name>.tmpl` defining `subject`,
   `plainBody` and `htmlBody`.
2. In the handler, copy what the template needs into a `map[string]any`, then
   send from `app.background`:

   ```go
   app.background(func() {
   	data := map[string]any{"userID": user.ID}

   	err := app.mailer.Send(user.Email, "<name>.tmpl", data)
   	if err != nil {
   		app.logger.Error(err.Error())
   	}
   })
   ```

## Add a token scope (e.g. password reset)

1. Add `ScopePasswordReset = "password-reset"` to the constants in
   `internal/data/tokens.go`.
2. A handler that looks up the user by email, creates the token with
   `Tokens.New(user.ID, ttl, data.ScopePasswordReset)` and emails it in the
   background, then return 202.
3. A handler that validates the token, loads the user with
   `Users.GetForToken(data.ScopePasswordReset, token)`, applies the change,
   `Users.Update`, then `Tokens.DeleteAllForUser(data.ScopePasswordReset, user.ID)`.
4. Routes for both, plus a template for the email.

## Add a permission

1. Migration: `INSERT INTO permissions (code) VALUES ('<resource>:<action>');`
   with a `.down.sql` that deletes it.
2. Wrap the route: `app.requireActivatedUserWithPermission("<resource>:<action>", handler)`.
3. Grant it: by default at registration (`registerUserHandler`), or to
   individual users with psql.

## Add a background job that runs on a schedule

Start it in `main()` or `serve()` with `app.background`, loop on a
`time.Ticker`, and stop when the server shuts down (pass a `done` channel or
context) so `app.wg.Wait()` doesn't hang.
