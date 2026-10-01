# Routing and middleware

## Routes (`cmd/api/routes.go`)

All routes live in one function, so the whole API surface reads top to
bottom:

```go
func (app *application) routes() http.Handler {
	router := httprouter.New()

	router.NotFound = http.HandlerFunc(app.notFoundResponse)
	router.MethodNotAllowed = http.HandlerFunc(app.methodNotAllowedResponse)

	router.HandlerFunc(http.MethodGet, "/v1/healthcheck", app.healthcheckHandler)

	router.HandlerFunc(http.MethodGet, "/v1/movies", app.requireActivatedUserWithPermission("movies:read", app.listMoviesHandler))
	router.HandlerFunc(http.MethodPost, "/v1/movies", app.requireActivatedUserWithPermission("movies:write", app.createMovieHandler))
	// ...

	router.HandlerFunc(http.MethodPost, "/v1/users", app.registerUserHandler)
	router.HandlerFunc(http.MethodPost, "/v1/tokens/authentication", app.createAuthenticationTokenHandler)

	router.Handler(http.MethodGet, "/debug/vars", expvar.Handler())

	return app.metrics(app.recoverPanic(app.enableCORS(app.rateLimit(app.authenticate(router)))))
}
```

- Register with `router.HandlerFunc(method, path, handler)` and
  `http.Method*` constants.
- Route-specific checks wrap the handler at the route
  (`requireActivatedUserWithPermission`). Checks for every request go in the
  chain on the last line.
- `/debug/vars` is open. In production, block it at the reverse proxy or put
  it behind auth.

## The chain, outermost first

| Order | Middleware | Why here |
| --- | --- | --- |
| 1 | `metrics` | counts and times every request, including ones the inner layers reject |
| 2 | `recoverPanic` | catches panics from every layer below it |
| 3 | `enableCORS` | before the rate limiter, so 429s carry CORS headers and the browser can read them |
| 4 | `rateLimit` | rejects floods before any database work |
| 5 | `authenticate` | runs the token lookup only for requests that got this far |
| — | `router` | dispatches to the handler |

Keep this order when adding middleware; decide where a new one goes by what
it needs to see and what should be skipped when it rejects a request.

## Writing a middleware

The standard shape: a method that takes `next http.Handler` and returns an
`http.Handler`.

```go
func (app *application) example(next http.Handler) http.Handler {
	// Setup here runs once, when routes() builds the chain.

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Code here runs on every request.
		next.ServeHTTP(w, r)
	})
}
```

- Reject a request with an error helper from `errors.go`, then `return`
  without calling `next`.
- A middleware that can be switched off returns `next` unchanged at setup,
  as `rateLimit` does when `-limiter-enabled=false`.
- Pass request-scoped values on through the context helpers in
  `cmd/api/context.go`, not through globals or headers.

## `recoverPanic`

A deferred `recover()`. On a panic it sets `Connection: close` (so Go closes
the connection after this response) and sends a 500 through
`serverErrorResponse`. It only covers the request's own goroutine; background
work must go through `app.background()`.

## `rateLimit`

- One `rate.Limiter` per client IP, stored in a map guarded by a
  `sync.Mutex`. The IP comes from `realip.FromRequest(r)`, which trusts
  `X-Forwarded-For` / `X-Real-IP`. Clients can set those headers themselves,
  so this is only reliable behind a proxy that overwrites them.
- A goroutine started at setup wakes every minute and deletes clients not seen
  for three minutes, so the map doesn't grow forever.
- Unlock the mutex **before** calling `next`, so one slow request doesn't
  block every other client.
- Configured with `-limiter-rps`, `-limiter-burst`, `-limiter-enabled`. The
  map is per process, so with several instances, rate limit at the load
  balancer instead.

## `enableCORS`

- Always add `Vary: Origin` and `Vary: Access-Control-Request-Method`, since
  the response depends on them and caches must know that.
- Compare `Origin` against `app.config.cors.trustedOrigins` exactly. Only a
  trusted origin is echoed back in `Access-Control-Allow-Origin`; never send
  `*`.
- A preflight is `OPTIONS` **with** an `Access-Control-Request-Method` header.
  Answer it directly: set `Access-Control-Allow-Methods` and
  `Access-Control-Allow-Headers` (`Authorization, Content-Type`), write 200
  and return without calling `next`.
- Logs `cors request` at debug level only.
- `cmd/examples/cors/simple` serves a page on `:9000` that calls the API, for
  testing CORS from a real browser.

## `metrics`

expvar counters created once at setup (`total_requests_received`,
`total_responses_sent`, `total_processing_time_μs`) and updated around
`next.ServeHTTP`. They appear at `/debug/vars` with the values published in
`main()`. The book goes on to count responses by status code with a wrapping
`ResponseWriter`; the reference project doesn't do that yet.

## `authenticate` and `requireActivatedUserWithPermission`

Covered in auth.md. In short: `authenticate` turns a valid
`Authorization: Bearer <token>` header into a user in the request context and
lets requests with no header through as anonymous; the route wrapper then
requires a logged-in, activated user with a given permission code.
