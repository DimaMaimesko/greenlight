package main

import (
	"context"
	"database/sql"
	"expvar"
	"flag"
	"log/slog"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"example.com/app/internal/data"
	"example.com/app/internal/mailer"
	"github.com/joho/godotenv"
	_ "github.com/lib/pq"
)

const version = "1.0.0"

type config struct {
	port int
	env  string

	db struct {
		dsn          string
		maxOpenConns int
		maxIdleConns int
		maxIdleTime  time.Duration
	}
	limiter struct {
		rps     float64
		burst   int
		enabled bool
	}
	smtp struct {
		host     string
		port     int
		username string
		password string
		sender   string
	}
	cors struct {
		trustedOrigins []string
	}
	logLevel slog.Level
}

// application holds the dependencies shared by every handler, helper and
// middleware.
type application struct {
	config config
	logger *slog.Logger
	models data.Models
	mailer *mailer.Mailer
	wg     sync.WaitGroup
}

func main() {
	// Load a .env file into the process environment if one is present, so that
	// the flag defaults below can pick the values up. A missing file is not an
	// error: in staging and production the variables are set by the runtime
	// (systemd, Docker, Kubernetes) rather than by a file. Values already
	// present in the environment always win over the file.
	_ = godotenv.Load()

	var cfg config

	flag.IntVar(&cfg.port, "port", envInt("APP_PORT", 4000), "API server port")
	flag.StringVar(&cfg.env, "env", envString("APP_ENV", "development"), "Environment (development|staging|production)")

	// slog.Level implements encoding.TextUnmarshaler, so flag.TextVar() parses
	// values like "debug" or "WARN" straight into it.
	flag.TextVar(&cfg.logLevel, "log-level", slog.LevelInfo, "Minimum log level (debug|info|warn|error)")

	flag.StringVar(&cfg.db.dsn, "db-dsn", os.Getenv("APP_DB_DSN"), "PostgreSQL DSN")

	flag.IntVar(&cfg.db.maxOpenConns, "db-max-open-conns", 25, "PostgreSQL max open connections")
	flag.IntVar(&cfg.db.maxIdleConns, "db-max-idle-conns", 25, "PostgreSQL max idle connections")
	flag.DurationVar(&cfg.db.maxIdleTime, "db-max-idle-time", 15*time.Minute, "PostgreSQL max connection idle time")

	flag.Float64Var(&cfg.limiter.rps, "limiter-rps", 2, "Rate limiter maximum requests per second")
	flag.IntVar(&cfg.limiter.burst, "limiter-burst", 4, "Rate limiter maximum burst")
	flag.BoolVar(&cfg.limiter.enabled, "limiter-enabled", true, "Enable rate limiter")

	// Read the SMTP server configuration settings into the config struct. The
	// credentials have no defaults on purpose: put them in .env (see
	// .env.example) rather than in this file.
	flag.StringVar(&cfg.smtp.host, "smtp-host", envString("APP_SMTP_HOST", "sandbox.smtp.mailtrap.io"), "SMTP host")
	flag.IntVar(&cfg.smtp.port, "smtp-port", envInt("APP_SMTP_PORT", 2525), "SMTP port")
	flag.StringVar(&cfg.smtp.username, "smtp-username", os.Getenv("APP_SMTP_USERNAME"), "SMTP username")
	flag.StringVar(&cfg.smtp.password, "smtp-password", os.Getenv("APP_SMTP_PASSWORD"), "SMTP password")
	flag.StringVar(&cfg.smtp.sender, "smtp-sender", envString("APP_SMTP_SENDER", "App <no-reply@example.com>"), "SMTP sender")
	// Trusted origins come from APP_CORS_TRUSTED_ORIGINS, and the
	// -cors-trusted-origins flag replaces them when passed. strings.Fields()
	// splits on whitespace and returns an empty slice for a blank value.
	cfg.cors.trustedOrigins = strings.Fields(os.Getenv("APP_CORS_TRUSTED_ORIGINS"))
	flag.Func("cors-trusted-origins", "Trusted CORS origins (space separated)", func(val string) error {
		cfg.cors.trustedOrigins = strings.Fields(val)
		return nil
	})

	flag.Parse()

	logger := slog.New(slog.NewTextHandler(os.Stdout, &slog.HandlerOptions{Level: cfg.logLevel}))

	if cfg.db.dsn == "" {
		logger.Error("no database DSN provided: set APP_DB_DSN (see .env.example) or pass -db-dsn")
		os.Exit(1)
	}

	db, err := openDB(cfg)
	if err != nil {
		logger.Error(err.Error())
		os.Exit(1)
	}
	defer db.Close()

	logger.Info("database connection pool established")

	mailer, err := mailer.New(cfg.smtp.host, cfg.smtp.port, cfg.smtp.username, cfg.smtp.password, cfg.smtp.sender)
	if err != nil {
		logger.Error(err.Error())
		os.Exit(1)
	}

	expvar.NewString("version").Set(version)

	// Publish the number of active goroutines.
	expvar.Publish("goroutines", expvar.Func(func() any {
		return runtime.NumGoroutine()
	}))

	// Publish the database connection pool statistics.
	expvar.Publish("database", expvar.Func(func() any {
		return db.Stats()
	}))

	// Publish the current Unix timestamp.
	expvar.Publish("timestamp", expvar.Func(func() any {
		return time.Now().Unix()
	}))

	app := &application{
		config: cfg,
		logger: logger,
		models: data.NewModels(db),
		mailer: mailer,
	}

	err = app.serve()
	if err != nil {
		logger.Error(err.Error())
		os.Exit(1)
	}
}

// envString returns the value of the environment variable named by key, falling
// back to the given default when the variable is unset or empty.
func envString(key, fallback string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return fallback
}

// envInt is the integer equivalent of envString. A value that is not a valid
// integer is treated the same as an unset one.
func envInt(key string, fallback int) int {
	val, err := strconv.Atoi(os.Getenv(key))
	if err != nil {
		return fallback
	}
	return val
}

// The openDB() function returns a sql.DB connection pool.
func openDB(cfg config) (*sql.DB, error) {
	db, err := sql.Open("postgres", cfg.db.dsn)
	if err != nil {
		return nil, err
	}

	db.SetMaxOpenConns(cfg.db.maxOpenConns)

	db.SetMaxIdleConns(cfg.db.maxIdleConns)

	db.SetConnMaxIdleTime(cfg.db.maxIdleTime)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	err = db.PingContext(ctx)
	if err != nil {
		db.Close()
		return nil, err
	}

	return db, nil
}
