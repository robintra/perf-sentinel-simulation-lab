package web

import (
	"encoding/json"
	"net/http"
	"time"
)

// FaultEnvelope mirrors the JSON shape the other multistack services
// emit: { antiPattern, service, durationMs, details, timestamp }.
type FaultEnvelope struct {
	AntiPattern string         `json:"antiPattern"`
	Service     string         `json:"service"`
	DurationMs  int64          `json:"durationMs"`
	Details     map[string]any `json:"details"`
	Timestamp   string         `json:"timestamp"`
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if body == nil {
		return
	}
	_ = json.NewEncoder(w).Encode(body)
}

func envelope(antiPattern, service string, start time.Time, details map[string]any) FaultEnvelope {
	return FaultEnvelope{
		AntiPattern: antiPattern,
		Service:     service,
		DurationMs:  time.Since(start).Milliseconds(),
		Details:     details,
		Timestamp:   time.Now().UTC().Format(time.RFC3339Nano),
	}
}
