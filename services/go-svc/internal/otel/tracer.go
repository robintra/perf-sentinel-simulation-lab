// Package otel wires the global OpenTelemetry TracerProvider for the
// go-svc lab service. Standard OTLP HTTP exporter, sampler driven by
// OTEL_TRACES_SAMPLER env (default always_on for the lab).
package otel

import (
	"context"
	"fmt"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	"go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// Shutdown is a thin wrapper around the SDK shutdown hook so callers
// don't need to import sdktrace.
type Shutdown func(context.Context) error

// Init configures the global TracerProvider + propagator and returns
// the shutdown hook. Reads OTEL_EXPORTER_OTLP_ENDPOINT / PROTOCOL etc.
// from environment.
func Init(ctx context.Context, serviceName string) (Shutdown, error) {
	exporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, fmt.Errorf("otlp http exporter: %w", err)
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(semconv.ServiceName(serviceName)),
		resource.WithFromEnv(),
		resource.WithProcess(),
	)
	if err != nil {
		return nil, fmt.Errorf("resource: %w", err)
	}

	tp := trace.NewTracerProvider(
		trace.WithBatcher(exporter),
		trace.WithResource(res),
		trace.WithSampler(trace.AlwaysSample()),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))
	return tp.Shutdown, nil
}
