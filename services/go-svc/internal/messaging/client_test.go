package messaging

import (
	"os"
	"testing"
)

func TestNewFromEnvUsesClusterFallbacksForMissingOrEmptyValues(t *testing.T) {
	for _, test := range []struct {
		name  string
		empty bool
	}{
		{name: "missing"},
		{name: "empty", empty: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			t.Setenv("RABBITMQ_USERNAME", "guest")
			t.Setenv("RABBITMQ_PASSWORD", "guest")
			t.Setenv("TOXIPROXY_API", "http://toxiproxy.messaging.svc.cluster.local:8474")
			for _, key := range []string{"RABBITMQ_HOST", "RABBITMQ_PORT", "RABBITMQ_SLOW_HOST", "RABBITMQ_SLOW_PORT"} {
				t.Setenv(key, "")
				if !test.empty {
					if err := os.Unsetenv(key); err != nil {
						t.Fatal(err)
					}
				}
			}

			client, err := NewFromEnv()
			if err != nil {
				t.Fatal(err)
			}
			if client.directAddress != "rabbitmq.messaging.svc.cluster.local:5672" {
				t.Fatalf("direct fallback = %q", client.directAddress)
			}
			if client.slowAddress != "toxiproxy.messaging.svc.cluster.local:25672" {
				t.Fatalf("slow fallback = %q", client.slowAddress)
			}
		})
	}
}
