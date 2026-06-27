class BusinessController < ApplicationController
  # GET /api/external/mock — the inert target the HTTP faults call back into.
  def mock
    delay = params[:delayMs].to_i
    sleep(delay / 1000.0) if delay.positive?
    render json: { ok: true, seq: params[:seq].to_i, op: params[:op].to_i, delayMs: delay }
  end

  # GET /api/dispatch/:channel — routed from "business#dispatch_channel"
  # (the action is NOT named `dispatch`: that collides with
  # ActionController::Metal#dispatch and would break request routing).
  def dispatch_channel
    channel = params[:channel]
    return render(json: { error: "unknown channel" }, status: :not_found) unless CHANNELS.include?(channel)

    delay = params[:delayMs].to_i
    sleep(delay / 1000.0) if delay.positive?
    render json: { channel: channel, dispatched: true, delayMs: delay }
  end

  # GET /api/payments/history — a real ActiveRecord read (ORM scope).
  def payments_history
    customer_id = (params[:customerId] || 1).to_i
    limit = [[(params[:limit] || 10).to_i, 1].max, 100].min
    rows = Payment.where(customer_id: customer_id).order(:id).limit(limit)
                  .pluck(:id, :order_id, :customer_id, :amount_cents, :status)
    render json: rows
  end
end
