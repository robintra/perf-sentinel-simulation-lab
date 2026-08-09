require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.eager_load = false
  config.enable_reloading = true
  config.cache_store = :null_store
  config.action_controller.perform_caching = false
  config.active_record.maintain_test_schema = false
end
