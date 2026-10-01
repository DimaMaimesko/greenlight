# Users, authentication and authorization

Stateful bearer tokens stored in Postgres, bcrypt passwords, email
activation, and permission codes per user. Tokens are rows rather than JWTs,
so a token is revoked by deleting it and there are no signing keys to manage.

## Tables (see migrations.md)

- `users`: `email citext UNIQUE` (case-insensitive), `password_hash bytea`,
  `activated bool`, `version`.
- `tokens`: `hash bytea PRIMARY KEY`, `user_id` (deleted with the user),
  `expiry`, `scope`.
- `permissions` (`id`, `code`) and `users_permissions` (`user_id`,
  `permission_id`), seeded by the migration with codes such as `movies:read`
  and `movies:write`.

## Passwords (`internal/data/users.go`)

```go
type password struct {
	plaintext *string
	hash      []byte
}
```

- `User.Password` is this unexported type with tag `json:"-"`, so the hash can
  never reach a response.
- `Set(plaintext)` hashes with bcrypt at cost 12 and keeps a pointer to the
  plaintext only so `ValidateUser` can check it.
- `Matches(plaintext) (bool, error)`: a mismatch is `false, nil`; only real
  failures are errors.
- `ValidatePasswordPlaintext`: 8 to 72 bytes. bcrypt can't hash more than 72.

## Tokens (`internal/data/tokens.go`)

- `generateToken` uses `crypto/rand.Text()`: 26 base32 characters, at least
  128 bits of randomness. `ValidateTokenPlaintext` checks for exactly 26
  characters, which saves a database query on obvious garbage.
- Only the SHA-256 of the plaintext is stored. A fast hash is fine here
  because the token is random and high-entropy; passwords need bcrypt because
  people choose them.
- The plaintext exists once: it goes into the response or the email, and
  can't be recovered later.
- Scopes are constants: `ScopeActivation`, `ScopeAuthentication`. A token only
  works for its own scope.
- `TokenModel.New(userID, ttl, scope)` generates and inserts;
  `DeleteAllForUser(scope, userID)` revokes.
- JSON shows only `token` and `expiry`.

## Flows

**Register: `POST /v1/users` (`registerUserHandler`)**
1. Decode name, email and password; build a `User` with `Activated: false`.
2. `user.Password.Set(input.Password)`, then `ValidateUser`.
3. `Users.Insert`; `ErrDuplicateEmail` becomes a 422 on the `email` field.
4. `Permissions.AddForUser(user.ID, "movies:read")`: the default grants.
5. `Tokens.New(user.ID, 3*24*time.Hour, data.ScopeActivation)`.
6. Send the welcome email with the token in `app.background`.
7. 202 Accepted with the user.

**Activate: `PUT /v1/users/activated` (`activateUserHandler`)**
1. `ValidateTokenPlaintext`.
2. `Users.GetForToken(data.ScopeActivation, token)`; not found becomes a 422
   `invalid or expired activation token`.
3. Set `Activated = true` and `Users.Update`; `ErrEditConflict` → 409.
4. `Tokens.DeleteAllForUser(data.ScopeActivation, user.ID)`, so the token
   can't be replayed.
5. 200 with the user.

**Log in: `POST /v1/tokens/authentication` (`createAuthenticationTokenHandler`)**
1. `ValidateEmail` and `ValidatePasswordPlaintext` → 422.
2. `Users.GetByEmail`; not found → 401 `invalidCredentialsResponse`.
3. `user.Password.Matches`; false → the **same** 401, so the response never
   says which part was wrong.
4. `Tokens.New(user.ID, 24*time.Hour, data.ScopeAuthentication)`.
5. 201 with `{"authentication_token": {"token": ..., "expiry": ...}}`.

## The `authenticate` middleware (`cmd/api/middleware.go`)

1. Always add `Vary: Authorization`.
2. No `Authorization` header: carry on as anonymous (nothing in the context).
3. Header present but not exactly `Bearer <token>`, wrong format, or no
   matching unexpired token: 401 via `invalidAuthenticationTokenResponse`,
   which also sets `WWW-Authenticate: Bearer`.
4. Otherwise `Users.GetForToken(data.ScopeAuthentication, token)` and store
   the user with `app.contextSetAuthenticatedUser(r, user)`.

`GetForToken` hashes the plaintext and joins `users` to `tokens` on hash,
scope and `expiry > now`, so the lookup is a single query.

## Request context (`cmd/api/context.go`)

- A private `type contextKey string` and the constant
  `authenticatedUserContextKey`, so no other package's keys can clash.
- `contextSetAuthenticatedUser(r, user) *http.Request` and
  `contextGetAuthenticatedUser(r) (data.User, bool)`. `false` means the
  request is anonymous. (The book stores an `AnonymousUser` and panics if the
  key is missing; this project returns a bool instead.)

## Authorization: `requireActivatedUserWithPermission(code, next)`

Wraps a single route's handler:

1. No user in the context → 401 `authenticationRequiredResponse`.
2. `!user.Activated` → 403 `inactiveAccountResponse`.
3. `Permissions.GetAllForUser(user.ID)`; missing `code` → 403
   `missingPermissionResponse`.

Permissions are read on every request, so a change applies at once, at the
cost of one query per protected request. Codes are `<resource>:<action>`.
There is no endpoint for granting them; insert into `users_permissions` with
psql or add an admin endpoint.

## Emails (`internal/mailer`)

- Templates are embedded with `//go:embed "templates"`. Each `.tmpl` file
  defines `subject`, `plainBody` and `htmlBody`; the mailer renders the first
  two with `text/template` and the HTML with `html/template`.
- `mailer.New(host, port, username, password, sender)` wraps a go-mail client
  with a 5-second timeout.
- `Send(recipient, templateFile, data)` retries up to 3 times, 500ms apart.
- Always send from `app.background`, never inline in the request.

## Security rules

- Never store or log plaintext passwords or tokens.
- Same error for an unknown email and a wrong password at login.
- Delete single-use tokens (activation) after use.
- Validate the token format before touching the database.
- Every lookup checks `expiry > now`. Nothing deletes expired rows yet; add
  a cleanup job if the `tokens` table grows large.
