require "net/http"
require "uri"

class ApplicationController < ActionController::API
  SERVICE = "rails-svc".freeze
  CHANNELS = %w[email sms push webhook slack teams].freeze

  private

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

  # Net::HTTP is OTel-instrumented, so each call emits a CLIENT span under
  # OpenTelemetry::Instrumentation::Net::HTTP, the shape the daemon needs for
  # the HTTP anti-patterns. Returns 1 on HTTP 200, else 0.
  def http_get(path)
    uri = URI("#{self_base}#{path}")
    res = Net::HTTP.start(uri.host, uri.port, open_timeout: 15, read_timeout: 15) do |http|
      http.get(uri.request_uri)
    end
    res.code == "200" ? 1 : 0
  rescue StandardError
    0
  end
end
