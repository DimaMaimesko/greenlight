package main

import (
	"context"
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.43.0"
)

// setupTracing configures the global OpenTelemetry tracer provider and returns
// a shutdown function that flushes any buffered spans.
//
// The four building blocks every OTel setup has:
//  1. Exporter   - WHERE spans go (OTLP over HTTP to Jaeger on :4318).
//  2. Resource   - WHO is sending them (service name/version/env; shows up
//     as searchable fields in the Jaeger UI).
//  3. Provider   - HOW spans are processed (batching, sampling).
//  4. Propagator - HOW trace context crosses process boundaries (the W3C
//     `traceparent` header), so a downstream service continues our trace.
func setupTracing(ctx context.Context, cfg config) (func(context.Context) error, error) {
	exporter, err := otlptracehttp.New(ctx,
		otlptracehttp.WithEndpoint(cfg.tracing.endpoint),
		otlptracehttp.WithInsecure(), // plain HTTP is fine for local Jaeger
	)
	if err != nil {
		return nil, fmt.Errorf("creating OTLP trace exporter: %w", err)
	}

	res, err := resource.Merge(
		resource.Default(),
		resource.NewWithAttributes(
			// MUST match the semconv version used by resource.Default()
			// (otel/sdk v1.45.0 -> semconv v1.43.0), otherwise Merge fails
			// with "conflicting Schema URL".
			semconv.SchemaURL,
			semconv.ServiceName("greenlight-api"),
			semconv.ServiceVersion(version),
			// `deployment.environment` was renamed to
			// `deployment.environment.name` and is an enum now, so we set the
			// attribute key directly instead of using a helper function.
			semconv.DeploymentEnvironmentNameKey.String(cfg.env),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("creating OTel resource: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		// Batcher buffers spans and exports them asynchronously — never
		// use the synchronous SimpleSpanProcessor in production.
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
		// ParentBased: honor the caller's sampling decision if there is one;
		// otherwise sample the given ratio of new traces (head-based sampling).
		// 1.0 locally so you see everything; in prod you'd use e.g. 0.1.
		sdktrace.WithSampler(sdktrace.ParentBased(
			sdktrace.TraceIDRatioBased(cfg.tracing.sampleRatio),
		)),
	)

	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{}, // W3C traceparent/tracestate headers
		propagation.Baggage{},      // key-value pairs that travel with the trace
	))

	return tp.Shutdown, nil
}
