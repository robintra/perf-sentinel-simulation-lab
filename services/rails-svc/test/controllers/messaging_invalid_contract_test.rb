ENV["DB_HOST"] = "127.0.0.1"
ENV["DB_PORT"] = "1"
ENV["OTEL_SDK_DISABLED"] = "true"

require_relative "../../config/environment"
require "rails/test_help"

class MessagingInvalidContractTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  class MessagingSpy
    attr_reader :publish_sequentially_calls, :publish_slowly_calls

    def initialize
      @publish_sequentially_calls = 0
      @publish_slowly_calls = 0
    end

    def publish_sequentially(_messages)
      @publish_sequentially_calls += 1
      raise "invalid request reached RabbitMQ"
    end

    def publish_slowly(_delay_ms, _repeats)
      @publish_slowly_calls += 1
      raise "invalid request reached RabbitMQ or Toxiproxy"
    end
  end

  class FailedStartConnection
    attr_reader :close_calls

    def initialize
      @close_calls = 0
    end

    def start
      raise "AMQP handshake failed"
    end

    def open?
      false
    end

    def close
      @close_calls += 1
    end
  end

  GLOBAL_INVALID = [
    "/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq",
    "/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq",
    "/api/fault/n-plus-one-messaging?messages=8&broker=unsupported",
  ].freeze

  STRICT_INPUT_INVALID = [
    "/api/fault/n-plus-one-messaging?messages[]=8&broker=rabbitmq",
    "/api/fault/n-plus-one-messaging?messages=8items&broker=rabbitmq",
    "/api/fault/n-plus-one-messaging?messages=%208&broker=rabbitmq",
    "/api/fault/n-plus-one-messaging?messages=%2B8&broker=rabbitmq",
    "/api/fault/n-plus-one-messaging?messages=999999999999999999999999999999&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs[]=600&repeats=3&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=600ms&repeats=3&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=%20600&repeats=3&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=%2B600&repeats=3&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=999999999999999999999999999999&repeats=3&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=600&repeats[]=3&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=600&repeats=3times&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=600&repeats=%203&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=600&repeats=%2B3&broker=rabbitmq",
    "/api/fault/slow-messaging?delayMs=600&repeats=999999999999999999999999999999&broker=rabbitmq",
  ].freeze

  test "invalid messaging parameters return 400 before constructing the messaging service" do
    assert_respond_to FaultController, :messaging_service_factory=

    spy = MessagingSpy.new
    factory_calls = 0
    previous_factory = FaultController.messaging_service_factory
    FaultController.messaging_service_factory = lambda do
      factory_calls += 1
      spy
    end

    begin
      (GLOBAL_INVALID + STRICT_INPUT_INVALID).each do |path|
        post path, headers: { "ACCEPT" => "application/json" }
        assert_response :bad_request, path
      end
    ensure
      FaultController.messaging_service_factory = previous_factory
    end

    assert_equal 0, factory_calls
    assert_equal 0, spy.publish_sequentially_calls
    assert_equal 0, spy.publish_slowly_calls
    puts "PERF_SENTINEL_MESSAGING_STRICT_INPUT_PASS #{STRICT_INPUT_INVALID.length}/#{STRICT_INPUT_INVALID.length} boundary_calls=0"
    puts "PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0"
  end

  test "a failed AMQP start still closes the connection" do
    connection = FailedStartConnection.new
    previous_username = ENV["RABBITMQ_USERNAME"]
    previous_password = ENV["RABBITMQ_PASSWORD"]
    ENV["RABBITMQ_USERNAME"] = "test"
    ENV["RABBITMQ_PASSWORD"] = "test"

    original_new = Bunny.method(:new)
    Bunny.define_singleton_method(:new) { |*_arguments| connection }
    assert_raises(RuntimeError) { MessagingFaultService.new.publish_sequentially(8) }
    assert_equal 1, connection.close_calls
  ensure
    Bunny.define_singleton_method(:new, original_new) if original_new
    previous_username.nil? ? ENV.delete("RABBITMQ_USERNAME") : ENV["RABBITMQ_USERNAME"] = previous_username
    previous_password.nil? ? ENV.delete("RABBITMQ_PASSWORD") : ENV["RABBITMQ_PASSWORD"] = previous_password
  end
end
