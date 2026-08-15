package web

import (
	"context"
	"net/http"
	"strconv"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var validChannels = map[string]struct{}{
	"email":   {},
	"sms":     {},
	"push":    {},
	"webhook": {},
	"slack":   {},
	"teams":   {},
}

// BusinessRoutes mounts /api/external/mock, /api/dispatch/{channel}
// and /api/payments/history. paymentsHistory returns positional arrays
// [id, order_id, customer_id, amount_cents, status], matches the
// multistack contract (helidon-mp / quarkus / mutiny / dotnet all do
// the same).
type BusinessRoutes struct {
	Pool *pgxpool.Pool
}

func (b *BusinessRoutes) Mount(r chi.Router) {
	r.Get("/external/mock", b.mock)
	r.Get("/dispatch/{channel}", b.dispatch)
	r.Get("/payments/history", b.paymentsHistory)
}

func (b *BusinessRoutes) mock(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	delayMs := atoiOr(q.Get("delayMs"), 0)
	seq := atoiOr(q.Get("seq"), 0)
	op := atoiOr(q.Get("op"), 0)
	if delayMs > 0 {
		time.Sleep(time.Duration(delayMs) * time.Millisecond)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"seq":     seq,
		"op":      op,
		"delayMs": delayMs,
	})
}

func (b *BusinessRoutes) dispatch(w http.ResponseWriter, r *http.Request) {
	channel := chi.URLParam(r, "channel")
	if _, ok := validChannels[channel]; !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "unknown channel"})
		return
	}
	delayMs := atoiOr(r.URL.Query().Get("delayMs"), 0)
	if delayMs > 0 {
		time.Sleep(time.Duration(delayMs) * time.Millisecond)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"channel":    channel,
		"dispatched": true,
		"delayMs":    delayMs,
	})
}

func (b *BusinessRoutes) paymentsHistory(w http.ResponseWriter, r *http.Request) {
	customerID := atoi64Or(r.URL.Query().Get("customerId"), 1)
	limit := atoiOr(r.URL.Query().Get("limit"), 10)
	if limit < 1 {
		limit = 1
	} else if limit > 100 {
		limit = 100
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	rows, err := b.Pool.Query(ctx,
		`SELECT id, order_id, customer_id, amount_cents, status
           FROM "go".payments WHERE customer_id = $1 ORDER BY id LIMIT $2`,
		customerID, limit)
	if err != nil {
		// Do not echo the driver message: same hygiene as the other
		// services (avoids leaking role/auth state).
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "payments query failed"})
		return
	}
	defer rows.Close()

	result := make([][]any, 0, limit)
	for rows.Next() {
		var id, orderID, custID, amount int64
		var status string
		if err := rows.Scan(&id, &orderID, &custID, &amount, &status); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "payments scan failed"})
			return
		}
		result = append(result, []any{id, orderID, custID, amount, status})
	}
	writeJSON(w, http.StatusOK, result)
}

func atoiOr(s string, fallback int) int {
	if s == "" {
		return fallback
	}
	v, err := strconv.Atoi(s)
	if err != nil {
		return fallback
	}
	return v
}

func atoi64Or(s string, fallback int64) int64 {
	if s == "" {
		return fallback
	}
	v, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		return fallback
	}
	return v
}
