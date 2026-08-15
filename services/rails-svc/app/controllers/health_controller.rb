class HealthController < ApplicationController
  # Liveness: cheap, no DB, the process is up.
  def live
    render json: { status: "UP" }
  end

  # Readiness: gated on a live DB round-trip.
  def ready
    ActiveRecord::Base.connection.execute("SELECT 1")
    render json: { status: "UP" }
  rescue StandardError
    render json: { status: "DOWN" }, status: :service_unavailable
  end
end
