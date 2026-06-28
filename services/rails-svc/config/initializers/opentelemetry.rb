# Configure OpenTelemetry once, during Rails initialize!, BEFORE the schema
# bootstrap or any request runs — so ActiveRecord is patched and every query
# carries the `OpenTelemetry::Instrumentation::ActiveRecord` scope.
#
# Exporter target, protocol, sampler and resource attributes all come from the
# OTEL_* env vars the helm deployment injects (OTEL_EXPORTER_OTLP_ENDPOINT,
# OTEL_EXPORTER_OTLP_PROTOCOL, OTEL_RESOURCE_ATTRIBUTES, OTEL_TRACES_SAMPLER).
# A short batch schedule delay lands spans inside the lab's ~15s validation
# flush window (mirrors django-svc's 1000ms).
require "opentelemetry/sdk"
require "opentelemetry/exporter/otlp"
require "opentelemetry/instrumentation/rails"
require "opentelemetry/instrumentation/pg"

ENV["OTEL_BSP_SCHEDULE_DELAY"] ||= "1000"

OpenTelemetry::SDK.configure do |c|
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "rails-svc")
  # Rails: Rack SERVER span + ActiveRecord ORM scope + ActionPack.
  c.use "OpenTelemetry::Instrumentation::Rails"
  # PG: the raw connections pool-saturation opens outside the AR pool.
  c.use "OpenTelemetry::Instrumentation::PG"
  # Net::HTTP auto-instrumentation is intentionally NOT enabled: in every
  # semconv mode its CLIENT spans omit `url.full`/`http.url`, and perf-sentinel
  # classifies a span as HTTP I/O ONLY when it carries one of those
  # (ingest/otlp.rs classify_io_event) — so its spans are dropped as
  # MissingHttpUrl and the HTTP anti-patterns never fire. ApplicationController#http_get
  # emits its own CLIENT span with `url.full` instead (one clean span, no dup).
end
