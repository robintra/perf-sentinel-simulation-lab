package web

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// FaultRoutes mounts the 10 perf-sentinel anti-pattern endpoints under
// /api/fault. SQL faults go through pgx with the otelpgx tracer
// attached (scope `github.com/exaring/otelpgx`). HTTP-side faults go
// through the otelhttp-wrapped http.Client passed in from main, so
// CLIENT spans land under the `go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp`
// scope.
type FaultRoutes struct {
	Pool       *pgxpool.Pool
	HTTPClient *http.Client
	SelfBase   string
}

const serviceName = "go-svc"

var channels = []string{"email", "sms", "push", "webhook", "slack", "teams"}

func (f *FaultRoutes) Mount(r chi.Router) {
	r.Post("/n-plus-one-sql", f.nPlusOneSQL)
	r.Post("/n-plus-one-http", f.nPlusOneHTTP)
	r.Post("/redundant-sql", f.redundantSQL)
	r.Post("/redundant-http", f.redundantHTTP)
	r.Post("/slow-sql", f.slowSQL)
	r.Post("/slow-http", f.slowHTTP)
	r.Post("/fanout", f.fanout)
	r.Post("/chatty", f.chatty)
	r.Post("/serialized", f.serialized)
	r.Post("/pool-saturation", f.poolSaturation)
}

// === SQL anti-patterns ===========================================================

func (f *FaultRoutes) nPlusOneSQL(w http.ResponseWriter, r *http.Request) {
	items := atoiOr(r.URL.Query().Get("items"), 15)
	start := time.Now()
	total := 0
	for orderID := 1; orderID <= items; orderID++ {
		// Parameterised pgx query. otelpgx emits one span per Exec/Query
		// under scope `github.com/exaring/otelpgx`. With the strict
		// classifier's ORM-marker list extended to include otelpgx,
		// these N statements keep the n+1_sql verdict; without, they
		// collapse to redundant_sql (Gap #20 expected on this stack).
		var c int
		err := f.Pool.QueryRow(r.Context(),
			`SELECT count(*) FROM "go".order_items WHERE order_id = $1`, orderID).Scan(&c)
		if err != nil {
			http.Error(w, "n-plus-one-sql failed", http.StatusInternalServerError)
			return
		}
		total += c
	}
	writeJSON(w, http.StatusOK, envelope("n_plus_one_sql", serviceName, start, map[string]any{
		"items":          items,
		"orders_touched": items,
		"items_total":    total,
	}))
}

func (f *FaultRoutes) redundantSQL(w http.ResponseWriter, r *http.Request) {
	repeats := atoiOr(r.URL.Query().Get("repeats"), 10)
	start := time.Now()
	total := 0
	for i := 0; i < repeats; i++ {
		var c int
		err := f.Pool.QueryRow(r.Context(),
			`SELECT count(*) FROM "go".payments WHERE customer_id = 1`).Scan(&c)
		if err != nil {
			http.Error(w, "redundant-sql failed", http.StatusInternalServerError)
			return
		}
		total += c
	}
	writeJSON(w, http.StatusOK, envelope("redundant_sql", serviceName, start, map[string]any{
		"repeats":      repeats,
		"queries_made": repeats,
		"rows_seen":    total,
	}))
}

func (f *FaultRoutes) slowSQL(w http.ResponseWriter, r *http.Request) {
	delayMs := atoi64Or(r.URL.Query().Get("delayMs"), 600)
	repeats := atoiOr(r.URL.Query().Get("repeats"), 6)
	start := time.Now()
	seconds := float64(delayMs) / 1000.0
	executed := 0
	for i := 0; i < repeats; i++ {
		// Literal interpolation, lab-intentional. fmt with %f uses
		// dot decimal in any locale (Go's strconv is locale-independent
		// by spec) — no comma/period drift risk.
		sql := fmt.Sprintf(
			`SELECT pg_sleep(%g), * FROM "go".orders ORDER BY id OFFSET %d LIMIT 1`,
			seconds, i)
		if _, err := f.Pool.Exec(r.Context(), sql); err != nil {
			http.Error(w, "slow-sql failed", http.StatusInternalServerError)
			return
		}
		executed++
	}
	writeJSON(w, http.StatusOK, envelope("slow_sql", serviceName, start, map[string]any{
		"delayMs":          delayMs,
		"repeats":          repeats,
		"queries_executed": executed,
		"delay_ms":         delayMs,
	}))
}

func (f *FaultRoutes) poolSaturation(w http.ResponseWriter, r *http.Request) {
	concurrency := atoiOr(r.URL.Query().Get("concurrency"), 20)
	start := time.Now()

	// Per-task context cap so a stuck acquire returns rather than
	// hanging the whole endpoint forever.
	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	var ok atomic.Int32
	var wg sync.WaitGroup
	wg.Add(concurrency)
	for i := 0; i < concurrency; i++ {
		go func() {
			defer wg.Done()
			if _, err := f.Pool.Exec(ctx, "SELECT pg_sleep(0.4)"); err == nil {
				ok.Add(1)
			}
		}()
	}
	wg.Wait()

	writeJSON(w, http.StatusOK, envelope("pool_saturation", serviceName, start, map[string]any{
		"concurrency":     concurrency,
		"tasks_launched":  concurrency,
		"tasks_completed": int(ok.Load()),
	}))
}

// === HTTP anti-patterns ==========================================================

func (f *FaultRoutes) doGet(ctx context.Context, path string) int {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, f.SelfBase+path, nil)
	if err != nil {
		return 0
	}
	resp, err := f.HTTPClient.Do(req)
	if err != nil {
		return 0
	}
	defer func() {
		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()
	}()
	if resp.StatusCode == http.StatusOK {
		return 1
	}
	return 0
}

func (f *FaultRoutes) nPlusOneHTTP(w http.ResponseWriter, r *http.Request) {
	recipients := atoiOr(r.URL.Query().Get("recipients"), 10)
	start := time.Now()
	ok := 0
	for i := 0; i < recipients; i++ {
		ok += f.doGet(r.Context(),
			fmt.Sprintf("/api/external/mock?delayMs=0&seq=%d&op=0", i))
	}
	writeJSON(w, http.StatusOK, envelope("n_plus_one_http", serviceName, start, map[string]any{
		"recipients": recipients,
		"calls_made": recipients,
		"calls_ok":   ok,
	}))
}

func (f *FaultRoutes) redundantHTTP(w http.ResponseWriter, r *http.Request) {
	repeats := atoiOr(r.URL.Query().Get("repeats"), 10)
	start := time.Now()
	ok := 0
	for i := 0; i < repeats; i++ {
		ok += f.doGet(r.Context(), "/api/payments/history?customerId=1&limit=10")
	}
	writeJSON(w, http.StatusOK, envelope("redundant_http", serviceName, start, map[string]any{
		"repeats":    repeats,
		"calls_made": repeats,
		"calls_ok":   ok,
	}))
}

func (f *FaultRoutes) slowHTTP(w http.ResponseWriter, r *http.Request) {
	delayMs := atoi64Or(r.URL.Query().Get("delayMs"), 600)
	repeats := atoiOr(r.URL.Query().Get("repeats"), 6)
	start := time.Now()
	ok := 0
	for i := 0; i < repeats; i++ {
		ok += f.doGet(r.Context(),
			fmt.Sprintf("/api/external/mock?delayMs=%d&seq=%d&op=0", delayMs, i))
	}
	writeJSON(w, http.StatusOK, envelope("slow_http", serviceName, start, map[string]any{
		"delayMs":    delayMs,
		"repeats":    repeats,
		"calls_made": repeats,
		"calls_ok":   ok,
		"delay_ms":   delayMs,
	}))
}

func (f *FaultRoutes) fanout(w http.ResponseWriter, r *http.Request) {
	width := atoiOr(r.URL.Query().Get("width"), 40)
	start := time.Now()
	var ok atomic.Int32
	var wg sync.WaitGroup
	wg.Add(width)
	for i := 0; i < width; i++ {
		seq := i
		go func() {
			defer wg.Done()
			ok.Add(int32(f.doGet(r.Context(),
				fmt.Sprintf("/api/external/mock?delayMs=10&seq=%d&op=0", seq))))
		}()
	}
	wg.Wait()
	writeJSON(w, http.StatusOK, envelope("excessive_fanout", serviceName, start, map[string]any{
		"width":             width,
		"children_launched": width,
		"children_ok":       int(ok.Load()),
	}))
}

func (f *FaultRoutes) chatty(w http.ResponseWriter, r *http.Request) {
	calls := atoiOr(r.URL.Query().Get("calls"), 30)
	start := time.Now()
	ok := 0
	for i := 0; i < calls; i++ {
		ok += f.doGet(r.Context(),
			fmt.Sprintf("/api/external/mock?delayMs=5&seq=%d&op=%d", i, i%7))
	}
	writeJSON(w, http.StatusOK, envelope("chatty_service", serviceName, start, map[string]any{
		"calls":      calls,
		"calls_made": calls,
		"calls_ok":   ok,
	}))
}

func (f *FaultRoutes) serialized(w http.ResponseWriter, r *http.Request) {
	steps := atoiOr(r.URL.Query().Get("steps"), 6)
	if steps > len(channels) {
		steps = len(channels)
	}
	start := time.Now()
	wcStart := time.Now()
	ok := 0
	for i := 0; i < steps; i++ {
		ok += f.doGet(r.Context(), fmt.Sprintf("/api/dispatch/%s?delayMs=80", channels[i]))
	}
	wallClockMs := time.Since(wcStart).Milliseconds()
	writeJSON(w, http.StatusOK, envelope("serialized_calls", serviceName, start, map[string]any{
		"steps":         steps,
		"steps_ok":      ok,
		"wall_clock_ms": wallClockMs,
	}))
}

// === route registration ==========================================================

// HealthHandler is exported so main.go can register the same handler
// on /health/live and /health/ready without duplicating logic.
func HealthHandler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(`{"status":"UP"}`))
}

// Mount registers everything under the http.Handler returned by
// chi.NewRouter(). The router is then wrapped by otelhttp.NewHandler
// in main.go so SERVER spans carry the right `http.route` template.
func Mount(pool *pgxpool.Pool, httpClient *http.Client, selfBase string) http.Handler {
	r := chi.NewRouter()
	r.Get("/health/live", HealthHandler)
	r.Get("/health/ready", HealthHandler)

	r.Route("/api", func(api chi.Router) {
		(&BusinessRoutes{Pool: pool}).Mount(api)
		api.Route("/fault", func(fr chi.Router) {
			(&FaultRoutes{Pool: pool, HTTPClient: httpClient, SelfBase: selfBase}).Mount(fr)
		})
	})

	return r
}

