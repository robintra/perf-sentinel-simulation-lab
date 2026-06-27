Rails.application.routes.draw do
  # Health (GET) — probed by the helm deployment.
  get "health/live",  to: "health#live"
  get "health/ready", to: "health#ready"

  # Business (GET) — the targets the HTTP faults call back into.
  get "api/external/mock",          to: "business#mock"
  get "api/dispatch/:channel",      to: "business#dispatch_channel"
  get "api/payments/history",       to: "business#payments_history"

  # Faults (POST) — mirror the multistack contract exactly.
  post "api/fault/n-plus-one-sql",  to: "fault#n_plus_one_sql"
  post "api/fault/n-plus-one-http", to: "fault#n_plus_one_http"
  post "api/fault/redundant-sql",   to: "fault#redundant_sql"
  post "api/fault/redundant-http",  to: "fault#redundant_http"
  post "api/fault/slow-sql",        to: "fault#slow_sql"
  post "api/fault/slow-http",       to: "fault#slow_http"
  post "api/fault/fanout",          to: "fault#fanout"
  post "api/fault/chatty",          to: "fault#chatty"
  post "api/fault/serialized",      to: "fault#serialized"
  post "api/fault/pool-saturation", to: "fault#pool_saturation"
end
