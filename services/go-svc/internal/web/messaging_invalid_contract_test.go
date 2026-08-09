package web

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
)

type messagingSpy struct {
	sequentialCalls atomic.Int32
	slowCalls       atomic.Int32
}

type successfulMessagingSpy struct {
	sequentialCalls atomic.Int32
	slowCalls       atomic.Int32
}

func (s *successfulMessagingSpy) PublishSequentially(_ context.Context, messages int) (map[string]any, error) {
	s.sequentialCalls.Add(1)
	return map[string]any{"published": messages, "confirmed": messages}, nil
}

func (s *successfulMessagingSpy) PublishSlowly(_ context.Context, _ int, repeats int) (map[string]any, error) {
	s.slowCalls.Add(1)
	return map[string]any{"published": repeats, "confirmed": repeats}, nil
}

func (s *messagingSpy) PublishSequentially(context.Context, int) (map[string]any, error) {
	s.sequentialCalls.Add(1)
	return nil, fmt.Errorf("unexpected sequential publish")
}

func (s *messagingSpy) PublishSlowly(context.Context, int, int) (map[string]any, error) {
	s.slowCalls.Add(1)
	return nil, fmt.Errorf("unexpected slow publish")
}

func TestMessagingInvalidContract(t *testing.T) {
	publisher := &messagingSpy{}
	handler := Mount(nil, nil, "", publisher)

	required := []string{
		"/api/fault/n-plus-one-messaging?messages=4&broker=rabbitmq",
		"/api/fault/n-plus-one-messaging?messages=101&broker=rabbitmq",
		"/api/fault/slow-messaging?delayMs=500&repeats=3&broker=rabbitmq",
		"/api/fault/slow-messaging?delayMs=5001&repeats=3&broker=rabbitmq",
		"/api/fault/slow-messaging?delayMs=600&repeats=2&broker=rabbitmq",
		"/api/fault/slow-messaging?delayMs=600&repeats=21&broker=rabbitmq",
		"/api/fault/n-plus-one-messaging?messages=8&broker=unsupported",
	}
	malformed := []string{
		"/api/fault/n-plus-one-messaging?messages=8x&broker=rabbitmq",
		"/api/fault/n-plus-one-messaging?messages=8&messages=9&broker=rabbitmq",
		"/api/fault/n-plus-one-messaging?messages%5B%5D=8&broker=rabbitmq",
		"/api/fault/n-plus-one-messaging?messages=4;ignored=x&broker=rabbitmq",
		"/api/fault/slow-messaging?delayMs=600x&repeats=3&broker=rabbitmq",
		"/api/fault/slow-messaging?delayMs%5B%5D=600&repeats=3&broker=rabbitmq",
		"/api/fault/slow-messaging?delayMs=600&repeats=3&repeats=4&broker=rabbitmq",
		"/api/fault/slow-messaging?delayMs=600&repeats=3&broker=rabbitmq&broker=rabbitmq",
	}

	for _, path := range append(required, malformed...) {
		t.Run(path, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, path, nil)
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, request)
			if response.Code != http.StatusBadRequest {
				t.Fatalf("status = %d, want 400; body=%s", response.Code, response.Body.String())
			}
		})
	}
	if got := publisher.sequentialCalls.Load(); got != 0 {
		t.Fatalf("sequential boundary calls = %d, want 0", got)
	}
	if got := publisher.slowCalls.Load(); got != 0 {
		t.Fatalf("slow boundary calls = %d, want 0", got)
	}
	fmt.Println("PERF_SENTINEL_MESSAGING_NEGATIVE_CONTRACT_PASS 7/7 boundary_calls=0")
}

func TestMessagingValidBounds(t *testing.T) {
	publisher := &successfulMessagingSpy{}
	handler := Mount(nil, nil, "", publisher)
	paths := []string{
		"/api/fault/n-plus-one-messaging?messages=5&broker=rabbitmq",
		"/api/fault/n-plus-one-messaging?messages=100&broker=rabbitmq",
		"/api/fault/slow-messaging?delayMs=501&repeats=3&broker=rabbitmq",
		"/api/fault/slow-messaging?delayMs=5000&repeats=20&broker=rabbitmq",
	}
	for _, path := range paths {
		response := httptest.NewRecorder()
		handler.ServeHTTP(response, httptest.NewRequest(http.MethodPost, path, nil))
		if response.Code != http.StatusOK {
			t.Fatalf("%s: status = %d, want 200; body=%s", path, response.Code, response.Body.String())
		}
	}
	if got := publisher.sequentialCalls.Load(); got != 2 {
		t.Fatalf("sequential boundary calls = %d, want 2", got)
	}
	if got := publisher.slowCalls.Load(); got != 2 {
		t.Fatalf("slow boundary calls = %d, want 2", got)
	}
}
