require "net/http"
require "uri"

class ApplicationController < ActionController::API
  SERVICE = "rails-svc".freeze
  CHANNELS = %w[email sms push webhook slack teams].freeze

  private

  # Coerce a query param to an integer, falling back to `default` for anything
  # that is not a plain scalar string. Rails parses bracketed params
  # (`?items[]=5`, `?items[a]=5`) as Array/Parameters, which have no `to_i`.
  # Without this guard those requests would 500 instead of running the fault.
  def int_param(key, default)
    value = params[key]
    value.is_a?(String) && !value.empty? ? value.to_i : default
  end

  def envelope(anti_pattern, start, details)
    render json: {
      antiPattern: anti_pattern,
      service: SERVICE,
      durationMs: ((monotonic - start) * 1000).to_i,
      details: details,
      timestamp: Time.now.utc.iso8601,
    }
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def self_base
    ENV.fetch("SELF_BASE_URL", "http://localhost:#{ENV.fetch('HTTP_PORT', '8094')}")
  end

  # Emit our own CLIENT span carrying `url.full` (the attribute perf-sentinel's
  # ingest needs to classify a span as HTTP I/O), rather than relying on the
  # Net::HTTP auto-instrumentation whose spans omit it. This is the shape the
  # daemon groups for the HTTP anti-patterns. Returns 1 on HTTP 200, else 0.
  def http_get(path)
    url = "#{self_base}#{path}"
    tracer = OpenTelemetry.tracer_provider.tracer("rails-svc-http")
    tracer.in_span("HTTP GET", kind: :client,
                   attributes: { "url.full" => url, "http.request.method" => "GET" }) do |span|
      uri = URI(url)
      res = Net::HTTP.start(uri.host, uri.port, open_timeout: 15, read_timeout: 15) do |http|
        http.get(uri.request_uri)
      end
      span.set_attribute("http.response.status_code", res.code.to_i)
      res.code == "200" ? 1 : 0
    end
  rescue StandardError
    0
  end
end
