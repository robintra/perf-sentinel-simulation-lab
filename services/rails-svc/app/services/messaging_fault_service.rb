require "bunny"
require "json"
require "net/http"
require "securerandom"
require "uri"

class MessagingFaultService
  DESTINATION = "perfsim.rails-svc".freeze
  ROUTING_KEY = "rails-svc".freeze
  DIRECT_TIMEOUT_SECONDS = 5

  def publish_sequentially(messages)
    confirmed = with_channel(slow: false, timeout: DIRECT_TIMEOUT_SECONDS) do |channel, exchange, returned|
      request_id = SecureRandom.uuid
      messages.times do |index|
        producer_span { publish(exchange, "rails-message-#{request_id}-#{index}") }
      end
      require_confirms(channel, returned)
      messages
    end

    { published: messages, confirmed: confirmed }
  end

  def publish_slowly(delay_ms, repeats)
    update_latency(delay_ms)
    operation_timeout = delay_ms / 1000.0 + DIRECT_TIMEOUT_SECONDS
    connection_timeout = 2 * operation_timeout + 1

    confirmed = with_channel(slow: true, timeout: connection_timeout, continuation_timeout: operation_timeout) do |channel, exchange, returned|
      request_id = SecureRandom.uuid
      repeats.times do |index|
        producer_span do
          publish(exchange, "slow-rails-message-#{request_id}-#{index}")
          require_confirms(channel, returned)
        end
      end
      repeats
    end

    { published: repeats, confirmed: confirmed, delay_ms: delay_ms }
  end

  private

  def with_channel(slow:, timeout:, continuation_timeout: timeout)
    username = required_env("RABBITMQ_USERNAME")
    password = required_env("RABBITMQ_PASSWORD")
    connection = Bunny.new(
      host: ENV.fetch(slow ? "RABBITMQ_SLOW_HOST" : "RABBITMQ_HOST",
                      slow ? "toxiproxy.messaging.svc.cluster.local" : "rabbitmq.messaging.svc.cluster.local"),
      port: Integer(ENV.fetch(slow ? "RABBITMQ_SLOW_PORT" : "RABBITMQ_PORT", slow ? "25672" : "5672"), 10),
      username: username,
      password: password,
      vhost: "/",
      automatically_recover: false,
      connection_timeout: timeout,
      read_timeout: timeout,
      write_timeout: timeout,
      continuation_timeout: (continuation_timeout * 1000).to_i,
    )
    channel = nil

    begin
      connection.start
      channel = connection.create_channel
      channel.confirm_select
      exchange = channel.direct(DESTINATION, durable: true, auto_delete: false)
      queue = channel.queue(
        DESTINATION,
        durable: true,
        auto_delete: false,
        arguments: { "x-message-ttl" => 60_000 },
      )
      queue.bind(exchange, routing_key: ROUTING_KEY)
      returned = []
      exchange.on_return { |info, _properties, _payload| returned << info }
      yield channel, exchange, returned
    ensure
      begin
        channel&.close if channel&.open?
      ensure
        connection.close
      end
    end
  end

  def publish(exchange, payload)
    exchange.publish(
      payload,
      routing_key: ROUTING_KEY,
      persistent: true,
      mandatory: true,
      content_type: "text/plain",
    )
  end

  def require_confirms(channel, returned)
    confirmed = channel.wait_for_confirms
    raise "RabbitMQ negatively acknowledged a publication" unless confirmed
    return if returned.empty?

    raise "RabbitMQ returned publication #{returned.first.reply_code}: #{returned.first.reply_text}"
  end

  def producer_span(&operation)
    OpenTelemetry.tracer_provider.tracer("rails-svc-messaging").in_span(
      "#{DESTINATION} send",
      kind: :producer,
      attributes: {
        "messaging.system" => "rabbitmq",
        "messaging.destination.name" => DESTINATION,
        "messaging.operation.type" => "send",
      },
      &operation
    )
  end

  def required_env(name)
    value = ENV[name]
    raise "#{name} is required" if value.nil? || value.empty?

    value
  end

  def update_latency(delay_ms)
    api = ENV.fetch("TOXIPROXY_API", "http://toxiproxy.messaging.svc.cluster.local:8474").delete_suffix("/")
    update = "#{api}/proxies/rabbitmq-slow/toxics/latency_downstream"
    status = post_json(update, attributes: { latency: delay_ms, jitter: 0 })
    if status == 404
      status = post_json("#{api}/proxies/rabbitmq-slow/toxics", {
        name: "latency_downstream",
        type: "latency",
        stream: "downstream",
        attributes: { latency: delay_ms, jitter: 0 },
      })
      status = post_json(update, attributes: { latency: delay_ms, jitter: 0 }) if status == 409
    end
    raise "Toxiproxy update failed with HTTP #{status}" unless status.between?(200, 299)
  end

  def post_json(url, body)
    uri = URI(url)
    request = Net::HTTP::Post.new(uri)
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(body)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.open_timeout = DIRECT_TIMEOUT_SECONDS
    http.read_timeout = DIRECT_TIMEOUT_SECONDS
    http.write_timeout = DIRECT_TIMEOUT_SECONDS
    http.start { |client| client.request(request) }.code.to_i
  end
end
