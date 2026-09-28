package lab;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.util.List;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.event.ApplicationReadyEvent;
import org.springframework.boot.web.server.context.WebServerApplicationContext;
import org.springframework.context.event.EventListener;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Modifying;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.client.RestClient;

/**
 * One inbound request, GET /work, runs five loops of six calls each: lazy
 * loads of a collection (aliased SELECT that no Hibernate span wraps), a
 * hand-written SELECT through JdbcTemplate, a derived query (aliased SELECT),
 * a bulk JPQL UPDATE (aliased, not a fetch) and RestClient GETs. Then the app
 * exits, which flushes the exporter.
 */
@SpringBootApplication
@EnableJpaRepositories(considerNestedRepositories = true)
@RestController
public class App {

    private final Work work;
    private final RestClient client;
    private final WebServerApplicationContext ctx;

    App(Work work, RestClient.Builder builder, WebServerApplicationContext ctx) {
        this.work = work;
        this.client = builder.build();
        this.ctx = ctx;
    }

    public static void main(String[] args) {
        SpringApplication.run(App.class, args);
    }

    @GetMapping("/api/ping/{id}")
    String ping(@PathVariable int id) {
        return "pong";
    }

    @GetMapping("/work")
    String work() {
        work.run();
        String base = "http://localhost:" + ctx.getWebServer().getPort();
        for (int i = 1; i <= 6; i++) {
            client.get().uri(base + "/api/ping/{id}", i).retrieve().toBodilessEntity();
        }
        return "done";
    }

    @EventListener(ApplicationReadyEvent.class)
    void drive(ApplicationReadyEvent event) throws Exception {
        HttpClient.newHttpClient().send(
                HttpRequest.newBuilder(URI.create("http://localhost:" + ctx.getWebServer().getPort() + "/work")).build(),
                HttpResponse.BodyHandlers.ofString());
        System.exit(SpringApplication.exit(event.getApplicationContext(), () -> 0));
    }

    @Service
    static class Work {
        private final AuthorRepo authors;
        private final BookRepo books;
        private final JdbcTemplate jdbc;

        Work(AuthorRepo authors, BookRepo books, JdbcTemplate jdbc) {
            this.authors = authors;
            this.books = books;
            this.jdbc = jdbc;
        }

        @Transactional
        public void run() {
            for (Author a : authors.findAll()) {
                a.books.size();
            }
            for (int i = 1; i <= 6; i++) {
                jdbc.queryForList("select id, title from book where author_id = ?", i);
            }
            for (int i = 1; i <= 6; i++) {
                books.findByTitle("b" + i);
            }
            for (int i = 1; i <= 6; i++) {
                books.retitle(i, "t" + i);
            }
        }
    }

    interface AuthorRepo extends JpaRepository<Author, Integer> { }

    interface BookRepo extends JpaRepository<Book, Integer> {
        List<Book> findByTitle(String title);

        @Modifying
        @Query("update Book b set b.title = ?2 where b.id = ?1")
        int retitle(int id, String title);
    }
}
