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
require "opentelemetry/instrumentation/net/http"
require "opentelemetry/instrumentation/pg"

ENV["OTEL_BSP_SCHEDULE_DELAY"] ||= "1000"

OpenTelemetry::SDK.configure do |c|
  c.service_name = ENV.fetch("OTEL_SERVICE_NAME", "rails-svc")
  # use_all activates every installed instrumentation: Rails (Rack SERVER span
  # + ActiveRecord ORM scope + ActionPack), Net::HTTP (outbound CLIENT spans),
  # and PG (raw pool-saturation connections).
  c.use_all
end
