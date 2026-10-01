# Configuration, logging and metrics

## Settings are flags whose defaults come from the environment

Every setting is a command-line flag parsed into the `config` struct in
`cmd/api/main.go`. Settings that change between environments, or are secret,
also read an environment variable, which becomes the flag's default. The
result, highest priority first:

1. a command-line flag
2. a real environment variable
3. a value in `.env` (`godotenv.Load()` never overrides a variable that is
   already set)
4. the default in code

```go
_ = godotenv.Load()

var cfg config

flag.IntVar(&cfg.port, "port", envInt("GREENLIGHT_PORT", 4000), "API server port")
flag.StringVar(&cfg.db.dsn, "db-dsn", os.Getenv("GREENLIGHT_DB_DSN"), "PostgreSQL DSN")
flag.DurationVar(&cfg.db.maxIdleTime, "db-max-idle-time", 15*time.Minute, "PostgreSQL max connection idle time")
flag.TextVar(&cfg.logLevel, "log-level", slog.LevelInfo, "Minimum log level (debug|info|warn|error)")

cfg.cors.trustedOrigins = strings.Fields(os.Getenv("GREENLIGHT_CORS_TRUSTED_ORIGINS"))
flag.Func("cors-trusted-origins", "Trusted CORS origins (space separated)", func(val string) error {
	cfg.cors.trustedOrigins = strings.Fields(val)
	return nil
})

flag.Parse()
```

- `envString(key, fallback)` and `envInt(key, fallback)` fall back when the
  variable is unset or empty; `envInt` also falls back on a value that isn't
  a number.
- Secrets get **no** default in code: `os.Getenv(...)` alone
  (`GREENLIGHT_DB_DSN`, `GREENLIGHT_SMTP_USERNAME`, `GREENLIGHT_SMTP_PASSWORD`).
- Required settings are checked right after `flag.Parse()` and the program
  exits with a message saying exactly how to fix it.
- Use the flag type that matches the value: `DurationVar` for durations,
  `TextVar` for anything implementing `encoding.TextUnmarshaler` (such as
  `slog.Level`), `flag.Func` for lists. A list is set from its environment
  variable first, so the flag only overrides it when passed.
- Tuning settings (pool sizes, limiter rates) can stay flag-only.

## The `config` struct

One nested anonymous struct per concern (shortened here; the real one is
gofmt-formatted in `cmd/api/main.go`):

```go
type config struct {
	port int
	env  string
	db struct {
		dsn          string
		maxOpenConns int
		maxIdleConns int
		maxIdleTime  time.Duration
	}
	limiter struct { rps float64; burst int; enabled bool }
	smtp    struct { host string; port int; username, password, sender string }
	cors    struct { trustedOrigins []string }
	logLevel slog.Level
}
```

Read it through `app.config` (`app.config.limiter.enabled`). Never read
environment variables anywhere else.

## Naming

- Environment variables: `<APP>_<SECTION>_<NAME>`, e.g. `GREENLIGHT_DB_DSN`,
  `GREENLIGHT_SMTP_HOST`. A scaffolded project uses its own prefix.
- Flags: kebab-case, prefixed by section: `-db-max-open-conns`,
  `-limiter-rps`, `-cors-trusted-origins`.
- Environments: `development`, `staging`, `production` via `-env`.

## `.env` and `.env.example`

- `.env.example` is committed and lists **every** environment variable with a
  safe example value or an empty value for secrets. Update it whenever you
  add one.
- `.env` is git-ignored; developers create it with `cp .env.example .env`.
  Staging and production set real environment variables and have no `.env`.
- The Makefile includes `.env` when it exists, so make targets use the same
  DSN. Make reads it as Makefile syntax, so keep values plain: no quotes, no
  `$`, no `#`.

## Logging (`log/slog`)

```go
logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.logLevel}))
```

- Structured key/value pairs: `app.logger.Info("starting server", "addr", srv.Addr, "env", app.config.env)`.
- Messages are short lowercase phrases; details go in attributes.
- Info: lifecycle events (pool established, starting, stopping, shutdown
  complete). Debug: per-request detail (`cors request`). Error: failures.
- Request errors are logged once, by `logError` in `cmd/api/errors.go`, with
  `method` and `uri`. Models and helpers return errors instead of logging them.
- The `http.Server`'s own error log goes through the same handler.

## Metrics (`expvar`)

`main()` publishes `version`, `goroutines` (`runtime.NumGoroutine`),
`database` (`db.Stats()`) and `timestamp`. The `metrics` middleware adds
request counters. Everything appears as JSON at `GET /debug/vars`. Publish new
values with `expvar.Publish(name, expvar.Func(...))` in `main()`.

## Version

`const version = "1.0.0"` in `main.go`, reported by the healthcheck and
expvar. The book later replaces it with a `-version` flag fed by build
information; the reference project hasn't done that yet.

## Adding a setting

1. Add a field to `config` under the right section.
2. Register the flag in `main()`, with an `envString` / `envInt` default if it
   changes between environments or is secret.
3. If it is required, check it after `flag.Parse()`.
4. Add the variable to `.env.example`, and to the README's configuration table
   if the project has one.
5. Use it through `app.config`.
