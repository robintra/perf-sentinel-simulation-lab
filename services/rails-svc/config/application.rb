require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module RailsSvc
  class Application < Rails::Application
    config.load_defaults 8.0

    # API-only: no views, no asset pipeline, no cookies/sessions.
    config.api_only = true

    # Production posture, but self-contained: eager load, log to stdout, no
    # on-disk cache (the container root filesystem is read-only).
    config.eager_load = true
    config.cache_classes = true
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = ENV.fetch("LOG_LEVEL", "info")
    config.cache_store = :null_store

    # Lab-only fixed secret; no signed/encrypted payloads are exchanged.
    config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "rails-svc-lab-not-a-secret")
  end
end
