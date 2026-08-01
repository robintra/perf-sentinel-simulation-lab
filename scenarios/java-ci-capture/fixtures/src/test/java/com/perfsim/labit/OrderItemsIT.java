package com.perfsim.labit;

import io.opentelemetry.api.GlobalOpenTelemetry;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.api.trace.SpanKind;
import io.opentelemetry.api.trace.Tracer;
import io.opentelemetry.context.Scope;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import org.junit.jupiter.api.Test;

/**
 * The integration test a CI pipeline would run: one request, one N+1 SQL fan-out.
 *
 * <p>The SERVER span is opened by hand because this project has no web framework
 * for the agent to instrument. In a real Failsafe suite it comes from the servlet
 * or JAX-RS instrumentation; either way the JDBC spans below are the agent's, and
 * what the scenario is actually testing is how they leave the JVM.
 */
class OrderItemsIT {

  private static int items() {
    String raw = System.getenv("LAB_ITEMS");
    return raw == null || raw.isBlank() ? 15 : Integer.parseInt(raw.trim());
  }

  /**
   * Creates and fills the table the test reads, so the fixture needs no external
   * seeding step. CI runners cannot always reach a package mirror to install a
   * psql client, and one self-contained test is simpler than three scenarios
   * each seeding the same rows their own way. Idempotent by construction.
   */
  private static void ensureSchema(Connection connection) throws Exception {
    try (Statement statement = connection.createStatement()) {
      statement.execute(
          "CREATE TABLE IF NOT EXISTS lab_order_items ("
              + "id serial PRIMARY KEY, order_id int NOT NULL)");
      statement.execute(
          "INSERT INTO lab_order_items (order_id) "
              + "SELECT g % 20 FROM generate_series(1, 200) g "
              + "WHERE NOT EXISTS (SELECT 1 FROM lab_order_items)");
    }
  }

  @Test
  void listsOrderItemsOneQueryAtATime() throws Exception {
    String url = System.getenv("LAB_DB_URL");
    if (url == null || url.isBlank()) {
      throw new IllegalStateException("LAB_DB_URL is not set, verify.sh should have set it");
    }

    // Before the span opens, and on its own connection: inside the traced scope
    // these statements would be captured as extra JDBC spans and change the very
    // count the assertions check.
    try (Connection setup = DriverManager.getConnection(url)) {
      ensureSchema(setup);
    }

    Tracer tracer = GlobalOpenTelemetry.getTracer("perf-sentinel-lab-it");
    Span request =
        tracer
            .spanBuilder("GET /orders/{id}/items")
            .setSpanKind(SpanKind.SERVER)
            .setAttribute("http.request.method", "GET")
            .setAttribute("url.path", "/orders/42/items")
            .startSpan();

    int total = 0;
    try (Scope ignored = request.makeCurrent();
        Connection connection = DriverManager.getConnection(url)) {
      for (int i = 0; i < items(); i++) {
        // The literal is concatenated so the statements stay distinct, the same
        // way services/order-service does it: an N+1 read one row at a time.
        try (Statement statement = connection.createStatement();
            ResultSet rs =
                statement.executeQuery(
                    "SELECT count(*) FROM lab_order_items WHERE order_id = " + i)) {
          if (rs.next()) {
            total += rs.getInt(1);
          }
        }
      }
    } finally {
      request.end();
    }

    if (total < 0) {
      throw new AssertionError("unreachable, keeps the query results live");
    }

    // D4 drives a real test failure through the wrapper: the spans are already
    // exported at this point, so the leg measures exit-code propagation on a run
    // that still produced traces.
    String fail = System.getenv("LAB_FAIL");
    if (fail != null && !fail.isBlank()) {
      throw new AssertionError("LAB_FAIL is set, failing on purpose");
    }
  }
}
