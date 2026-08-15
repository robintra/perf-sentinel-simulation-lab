# Single-mode puma (no cluster workers): one process keeps the OpenTelemetry
# SDK + its BatchSpanProcessor thread simple (no fork handling), and 8 threads
# match django's 2 workers x 4 threads of concurrency, enough for the k6 load
# and the self-calling fanout/pool-saturation faults (which spawn their own
# Ruby threads anyway). Bind to the helm-injected HTTP_PORT (default 8094).
port ENV.fetch("HTTP_PORT", "8094")
environment ENV.fetch("RAILS_ENV", "production")

threads_count = Integer(ENV.fetch("RAILS_MAX_THREADS", "8"))
threads threads_count, threads_count

# Keep writable state off the read-only root filesystem (emptyDir at /tmp).
pidfile "/tmp/puma.pid"
state_path "/tmp/puma.state"
