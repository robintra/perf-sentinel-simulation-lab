package lab;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.boot.web.server.context.WebServerApplicationContext;
import org.springframework.context.event.EventListener;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

/**
 * One inbound request, GET /batch, fanning out through the auto-configured,
 * observed RestClient: 6 POSTs and 6 GETs to /api/items/{id}, one GET answered
 * 404, one call to a closed port (no response, Micrometer tags it
 * status=CLIENT_ERROR). Then the app exits, which flushes the exporter.
 */
@SpringBootApplication
@RestController
public class App {

    private final RestClient client;
    private final WebServerApplicationContext ctx;

    App(RestClient.Builder builder, WebServerApplicationContext ctx) {
        this.client = builder.build();
        this.ctx = ctx;
    }

    public static void main(String[] args) {
        SpringApplication.run(App.class, args);
    }

    @PostMapping("/api/items/{id}")
    ResponseEntity<String> create(@PathVariable int id) {
        return ResponseEntity.status(201).body("created");
    }

    @GetMapping("/api/items/{id}")
    ResponseEntity<String> read(@PathVariable int id) {
        return id == 404 ? ResponseEntity.notFound().build() : ResponseEntity.ok("item");
    }

    @GetMapping("/batch")
    String batch() {
        String base = "http://localhost:" + ctx.getWebServer().getPort();
        for (int i = 1; i <= 6; i++) {
            client.post().uri(base + "/api/items/{id}", i).retrieve().toBodilessEntity();
        }
        for (int i = 1; i <= 6; i++) {
            client.get().uri(base + "/api/items/{id}", 100 + i).retrieve().toBodilessEntity();
        }
        client.get().uri(base + "/api/items/{id}", 404).retrieve()
                .onStatus(s -> true, (req, res) -> { }).toBodilessEntity();
        try {
            client.get().uri("http://127.0.0.1:1/api/unreachable").retrieve().toBodilessEntity();
        } catch (RuntimeException expected) {
            // connection refused: the span closes without a response
        }
        return "done";
    }

    @EventListener(ApplicationReadyEvent.class)
    void drive(ApplicationReadyEvent event) throws Exception {
        // Unobserved JDK client, so the trace root is the inbound /batch span.
        HttpClient.newHttpClient().send(
                HttpRequest.newBuilder(URI.create("http://localhost:" + ctx.getWebServer().getPort() + "/batch")).build(),
                HttpResponse.BodyHandlers.ofString());
        System.exit(SpringApplication.exit(event.getApplicationContext(), () -> 0));
    }
}
