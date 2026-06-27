# Puma entrypoint. OpenTelemetry is configured in
# config/initializers/opentelemetry.rb (loaded during initialize!), which
# patches ActiveRecord BEFORE the schema bootstrap and any request runs, so
# every query carries the OpenTelemetry::Instrumentation::ActiveRecord scope.
require_relative "config/environment"

# Idempotent schema + seed bootstrap (advisory-locked), after AR is connected.
require_relative "lib/schema_bootstrap"
SchemaBootstrap.run!

run Rails.application
