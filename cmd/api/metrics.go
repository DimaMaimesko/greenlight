package main

import (
	"database/sql"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/julienschmidt/httprouter"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

type metrics struct {
	registry *prometheus.Registry

	requestsTotal    *prometheus.CounterVec
	requestDuration  *prometheus.HistogramVec
	requestsInFlight prometheus.Gauge

	panicsTotal          prometheus.Counter
	backgroundTasksTotal *prometheus.CounterVec
}

func newMetrics(db *sql.DB) *metrics {
	// Use our own registry instead of the global default one, so we control
	// exactly what is exposed.
	reg := prometheus.NewRegistry()

	// Built-in collectors: Go runtime (goroutines, GC, heap...) and process
	// stats (CPU, memory, fds). These replace the expvar "goroutines" metric
	// with far richer data.
	reg.MustRegister(
		collectors.NewGoCollector(),
		collectors.NewProcessCollector(collectors.ProcessCollectorOpts{}),
		// Exposes sql.DBStats: open/idle/in-use connections, wait counts...
		// This replaces the expvar "database" metric (USE method for the pool).
		collectors.NewDBStatsCollector(db, "greenlight"),
	)

	m := &metrics{
		registry: reg,

		// RED: Rate + Errors come from this counter.
		requestsTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests processed.",
		}, []string{"method", "route", "status"}),

		// RED: Duration. Histogram buckets let us compute p50/p95/p99.
		requestDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency in seconds.",
			Buckets: []float64{0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5},
		}, []string{"method", "route"}),

		// Saturation signal: how many requests are being handled right now.
		requestsInFlight: prometheus.NewGauge(prometheus.GaugeOpts{
			Name: "http_requests_in_flight",
			Help: "Current number of in-flight HTTP requests.",
		}),

		// Panics recovered by the recoverPanic middleware. A panic-driven 500
		// is a stronger signal than a regular 500, so track it separately.
		panicsTotal: prometheus.NewCounter(prometheus.CounterOpts{
			Name: "http_panics_recovered_total",
			Help: "Total number of panics recovered by middleware.",
		}),

		// Fire-and-forget goroutines (e.g. welcome emails) are invisible to
		// HTTP metrics — this is the only way to know they're failing.
		backgroundTasksTotal: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "background_tasks_total",
			Help: "Background tasks by name and result (ok|error).",
		}, []string{"task", "result"}),
	}

	// Standard pattern: a gauge that is always 1, with the version as a label.
	// Lets you correlate metric changes with deployments in Grafana.
	buildInfo := prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "greenlight_build_info",
		Help: "Build information.",
	}, []string{"version"})
	buildInfo.WithLabelValues(version).Set(1)

	reg.MustRegister(m.requestsTotal, m.requestDuration, m.requestsInFlight,
		m.panicsTotal, m.backgroundTasksTotal, buildInfo)

	return m
}

// metricsResponseWriter wraps http.ResponseWriter to capture the status code,
// which the standard ResponseWriter doesn't expose.
type metricsResponseWriter struct {
	http.ResponseWriter
	statusCode    int
	headerWritten bool
}

func (mw *metricsResponseWriter) WriteHeader(statusCode int) {
	if !mw.headerWritten {
		mw.statusCode = statusCode
		mw.headerWritten = true
	}
	mw.ResponseWriter.WriteHeader(statusCode)
}

func (mw *metricsResponseWriter) Write(b []byte) (int, error) {
	mw.headerWritten = true
	return mw.ResponseWriter.Write(b)
}

// routePattern converts a concrete URL path like /v1/movies/42 back into its
// route template /v1/movies/:id. This is CRITICAL to keep label cardinality
// bounded — never put raw paths or IDs into metric labels!
func routePattern(router *httprouter.Router, r *http.Request) string {
	handle, params, _ := router.Lookup(r.Method, r.URL.Path)
	if handle == nil {
		return "unmatched"
	}

	route := r.URL.Path
	for _, p := range params {
		route = strings.Replace(route, p.Value, ":"+p.Key, 1)
	}
	return route
}

// prometheusMetrics is the middleware that instruments every request.
func (app *application) prometheusMetrics(router *httprouter.Router, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()

		app.metrics.requestsInFlight.Inc()
		defer app.metrics.requestsInFlight.Dec()

		mw := &metricsResponseWriter{ResponseWriter: w, statusCode: http.StatusOK}

		next.ServeHTTP(mw, r)

		route := routePattern(router, r)
		status := strconv.Itoa(mw.statusCode)

		app.metrics.requestsTotal.WithLabelValues(r.Method, route, status).Inc()
		app.metrics.requestDuration.WithLabelValues(r.Method, route).Observe(time.Since(start).Seconds())
	})
}
