package messaging

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	amqp "github.com/rabbitmq/amqp091-go"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/trace"
)

const (
	exchangeName = "perfsim.go-svc"
	routingKey   = "go-svc"
	queueTTL     = int32(60_000)
)

var tracer = otel.Tracer("go-svc/messaging")

type Client struct {
	directAddress string
	slowAddress   string
	toxiproxyAPI  string
	username      string
	password      string
}

type session struct {
	connection *amqp.Connection
	channel    *amqp.Channel
	transport  net.Conn
	returned   chan amqp.Return
}

type pendingPublish struct {
	confirmation *amqp.DeferredConfirmation
	span         trace.Span
}

func NewFromEnv() (*Client, error) {
	username := strings.TrimSpace(os.Getenv("RABBITMQ_USERNAME"))
	password := os.Getenv("RABBITMQ_PASSWORD")
	if username == "" || password == "" {
		return nil, errors.New("RABBITMQ_USERNAME and RABBITMQ_PASSWORD are required")
	}
	direct, err := addressFromEnv("RABBITMQ_HOST", "rabbitmq.messaging.svc.cluster.local", "RABBITMQ_PORT", 5672)
	if err != nil {
		return nil, err
	}
	slow, err := addressFromEnv("RABBITMQ_SLOW_HOST", "toxiproxy.messaging.svc.cluster.local", "RABBITMQ_SLOW_PORT", 25672)
	if err != nil {
		return nil, err
	}
	toxi := strings.TrimRight(os.Getenv("TOXIPROXY_API"), "/")
	parsed, err := url.Parse(toxi)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" {
		return nil, errors.New("TOXIPROXY_API must be an HTTP(S) base URL")
	}
	return &Client{directAddress: direct, slowAddress: slow, toxiproxyAPI: toxi, username: username, password: password}, nil
}

func addressFromEnv(hostKey, hostFallback, portKey string, portFallback int) (string, error) {
	host := strings.TrimSpace(os.Getenv(hostKey))
	if host == "" {
		host = hostFallback
	}
	port := portFallback
	if raw := os.Getenv(portKey); raw != "" {
		parsed, err := strconv.Atoi(raw)
		if err != nil || parsed < 1 || parsed > 65_535 {
			return "", fmt.Errorf("%s must be a valid TCP port", portKey)
		}
		port = parsed
	}
	return net.JoinHostPort(host, strconv.Itoa(port)), nil
}

func (c *Client) PublishSequentially(ctx context.Context, messages int) (map[string]any, error) {
	const operationTimeout = 5 * time.Second
	s, err := c.openSession(ctx, c.directAddress, operationTimeout, messages)
	if err != nil {
		return nil, err
	}
	defer s.close()

	pending := make([]pendingPublish, 0, messages)
	requestID := time.Now().UnixNano()
	for i := 0; i < messages; i++ {
		if err := s.setOperationDeadline(operationTimeout); err != nil {
			finishPending(pending, err)
			return nil, err
		}
		publishCtx, cancel := context.WithTimeout(ctx, operationTimeout)
		spanCtx, span := startProducerSpan(publishCtx)
		confirmation, publishErr := s.channel.PublishWithDeferredConfirmWithContext(
			spanCtx, exchangeName, routingKey, true, false,
			amqp.Publishing{
				DeliveryMode: amqp.Persistent,
				ContentType:  "text/plain",
				Body:         []byte(fmt.Sprintf("go-message-%d-%d", requestID, i)),
			},
		)
		cancel()
		pending = append(pending, pendingPublish{confirmation: confirmation, span: span})
		if publishErr != nil || confirmation == nil {
			if publishErr == nil {
				publishErr = errors.New("publisher confirmation was not registered")
			}
			finishPending(pending, publishErr)
			return nil, publishErr
		}
	}

	confirmCtx, cancel := context.WithTimeout(ctx, operationTimeout)
	defer cancel()
	if err := s.setOperationDeadline(operationTimeout); err != nil {
		finishPending(pending, err)
		return nil, err
	}
	for _, publish := range pending {
		acknowledged, waitErr := publish.confirmation.WaitContext(confirmCtx)
		if waitErr != nil || !acknowledged || !publish.confirmation.Acked() {
			if waitErr == nil {
				waitErr = errors.New("RabbitMQ negatively acknowledged a message")
			}
			finishPending(pending, waitErr)
			return nil, waitErr
		}
	}
	if err := returnedError(s.returned); err != nil {
		finishPending(pending, err)
		return nil, err
	}
	finishPending(pending, nil)
	return map[string]any{"broker": "rabbitmq", "confirmed": messages, "destination": exchangeName, "messages": messages, "published": messages}, nil
}

func (c *Client) PublishSlowly(ctx context.Context, delayMs, repeats int) (map[string]any, error) {
	if err := c.setLatency(ctx, delayMs); err != nil {
		return nil, err
	}
	operationTimeout := time.Duration(delayMs)*time.Millisecond + 5*time.Second
	s, err := c.openSession(ctx, c.slowAddress, operationTimeout, repeats)
	if err != nil {
		return nil, err
	}
	defer s.close()

	requestID := time.Now().UnixNano()
	for i := 0; i < repeats; i++ {
		if err := s.setOperationDeadline(operationTimeout); err != nil {
			return nil, err
		}
		publishCtx, cancel := context.WithTimeout(ctx, operationTimeout)
		spanCtx, span := startProducerSpan(publishCtx)
		confirmation, publishErr := s.channel.PublishWithDeferredConfirmWithContext(
			spanCtx, exchangeName, routingKey, true, false,
			amqp.Publishing{
				DeliveryMode: amqp.Persistent,
				ContentType:  "text/plain",
				Body:         []byte(fmt.Sprintf("go-slow-message-%d-%d", requestID, i)),
			},
		)
		if publishErr == nil && confirmation == nil {
			publishErr = errors.New("publisher confirmation was not registered")
		}
		if publishErr == nil {
			var acknowledged bool
			acknowledged, publishErr = confirmation.WaitContext(publishCtx)
			if publishErr == nil && (!acknowledged || !confirmation.Acked()) {
				publishErr = errors.New("RabbitMQ negatively acknowledged a message")
			}
		}
		if publishErr == nil {
			publishErr = returnedError(s.returned)
		}
		cancel()
		finishSpan(span, publishErr)
		if publishErr != nil {
			return nil, publishErr
		}
	}
	return map[string]any{"broker": "rabbitmq", "confirmed": repeats, "delay_ms": delayMs, "destination": exchangeName, "published": repeats, "repeats": repeats}, nil
}

func (c *Client) openSession(ctx context.Context, address string, operationTimeout time.Duration, returnBuffer int) (*session, error) {
	setupTimeout := 8 * operationTimeout
	setupCtx, cancel := context.WithTimeout(ctx, setupTimeout)
	defer cancel()
	var transport net.Conn
	connection, err := amqp.DialConfig("amqp://"+address+"/", amqp.Config{
		SASL:     []amqp.Authentication{&amqp.PlainAuth{Username: c.username, Password: c.password}},
		Recovery: nil,
		Dial: func(network, target string) (net.Conn, error) {
			conn, dialErr := (&net.Dialer{}).DialContext(setupCtx, network, target)
			if dialErr == nil {
				if deadlineErr := conn.SetDeadline(time.Now().Add(setupTimeout)); deadlineErr != nil {
					_ = conn.Close()
					return nil, deadlineErr
				}
				transport = conn
			}
			return conn, dialErr
		},
	})
	if err != nil {
		return nil, fmt.Errorf("connect to RabbitMQ: %w", err)
	}
	failed := true
	defer func() {
		if failed {
			_ = connection.CloseDeadline(time.Now().Add(2 * time.Second))
		}
	}()
	if transport == nil {
		return nil, errors.New("RabbitMQ transport unavailable")
	}
	if err := transport.SetDeadline(time.Now().Add(setupTimeout)); err != nil {
		return nil, err
	}
	channel, err := connection.Channel()
	if err == nil {
		err = channel.ExchangeDeclare(exchangeName, "direct", true, false, false, false, nil)
	}
	if err == nil {
		_, err = channel.QueueDeclare(exchangeName, true, false, false, false, amqp.Table{"x-message-ttl": queueTTL})
	}
	if err == nil {
		err = channel.QueueBind(exchangeName, routingKey, exchangeName, false, nil)
	}
	if err == nil {
		err = channel.Confirm(false)
	}
	if err != nil {
		return nil, fmt.Errorf("configure RabbitMQ topology: %w", err)
	}
	if err := transport.SetDeadline(time.Now().Add(operationTimeout)); err != nil {
		return nil, err
	}
	failed = false
	return &session{connection: connection, channel: channel, transport: transport, returned: channel.NotifyReturn(make(chan amqp.Return, returnBuffer))}, nil
}

func (s *session) close() {
	_ = s.transport.SetDeadline(time.Now().Add(2 * time.Second))
	_ = s.connection.CloseDeadline(time.Now().Add(2 * time.Second))
}

func (s *session) setOperationDeadline(timeout time.Duration) error {
	return s.transport.SetDeadline(time.Now().Add(timeout))
}

func startProducerSpan(ctx context.Context) (context.Context, trace.Span) {
	return tracer.Start(ctx, exchangeName+" send",
		trace.WithSpanKind(trace.SpanKindProducer),
		trace.WithAttributes(
			attribute.String("messaging.system", "rabbitmq"),
			attribute.String("messaging.destination.name", exchangeName),
			attribute.String("messaging.operation.type", "send"),
		),
	)
}

func finishPending(pending []pendingPublish, err error) {
	for _, publish := range pending {
		finishSpan(publish.span, err)
	}
}

func finishSpan(span trace.Span, err error) {
	if err != nil {
		span.RecordError(err)
		span.SetStatus(codes.Error, "RabbitMQ publish failed")
	}
	span.End()
}

func returnedError(returned <-chan amqp.Return) error {
	select {
	case returnedMessage := <-returned:
		return fmt.Errorf("RabbitMQ returned unroutable message: %d %s", returnedMessage.ReplyCode, returnedMessage.ReplyText)
	default:
		return nil
	}
}

func (c *Client) setLatency(ctx context.Context, delayMs int) error {
	updateBody := map[string]any{"attributes": map[string]int{"latency": delayMs, "jitter": 0}}
	status, err := c.toxiproxyRequest(ctx, http.MethodPost, "/proxies/rabbitmq-slow/toxics/latency_downstream", updateBody)
	if err != nil {
		return err
	}
	if status == http.StatusNotFound {
		createBody := map[string]any{
			"name": "latency_downstream", "type": "latency", "stream": "downstream",
			"attributes": map[string]int{"latency": delayMs, "jitter": 0},
		}
		status, err = c.toxiproxyRequest(ctx, http.MethodPost, "/proxies/rabbitmq-slow/toxics", createBody)
		if err == nil && status == http.StatusConflict {
			status, err = c.toxiproxyRequest(ctx, http.MethodPost, "/proxies/rabbitmq-slow/toxics/latency_downstream", updateBody)
		}
	}
	if err != nil {
		return err
	}
	if status < http.StatusOK || status >= http.StatusMultipleChoices {
		return fmt.Errorf("Toxiproxy returned HTTP %d", status)
	}
	return nil
}

func (c *Client) toxiproxyRequest(ctx context.Context, method, path string, payload any) (int, error) {
	body, err := json.Marshal(payload)
	if err != nil {
		return 0, err
	}
	requestCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(requestCtx, method, c.toxiproxyAPI+path, bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 5 * time.Second}).Do(request)
	if err != nil {
		return 0, fmt.Errorf("configure Toxiproxy: %w", err)
	}
	defer response.Body.Close()
	_, _ = io.Copy(io.Discard, response.Body)
	return response.StatusCode, nil
}
