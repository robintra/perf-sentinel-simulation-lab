# hibernate-alias-suggestion

Which suggested fix a Java finding gets when no span of it names Hibernate. A
Spring Boot 4 + Spring Data JPA application runs under the OTel Java agent,
under the agent with its Hibernate and Spring Data instrumentation off, and
under the Micrometer bridge of `spring-boot-starter-opentelemetry`.

## Why it exists

The JPA fix (`java_jpa`) used to need a Hibernate or Spring Data scope, or a
code location naming a repository, on the finding's own spans. The OTel agent
wraps a query or a repository call in such a span, but not the load of a lazy
collection: that SELECT reaches perf-sentinel as a bare `io.opentelemetry.jdbc`
span, so the most common N+1 of a JPA application got the Java generic fix up
to 0.25.2. A service traced through Micrometer got no fix at all, since its
only scope, `org.springframework.boot`, named no language.

0.25.3 reads Hibernate's table aliases (`b1_0`) on a SELECT whose alias is also
declared after its table, and leaves out a bulk UPDATE or DELETE, which carries
the same aliases but is not a fetch. It strips the leading block comment that
`hibernate.use_sql_comments` adds, and reads `org.springframework.boot` as
Java.

## What it asserts

| id | assertion |
|----|-----------|
| B0 | both fixture profiles build (default, `micrometer`) |
| A0 | agent: the lazy-load finding names no Hibernate or Spring Data scope and no code location |
| A1 | agent: lazy loads get `java_jpa` |
| A2 | agent: the hand-written JdbcTemplate SELECT gets `java_generic` |
| A3 | agent: the derived query and the bulk UPDATE, under a Hibernate span, get `java_jpa` |
| C0 | bare agent: no finding names Hibernate or Spring Data, and the derived query and the UPDATE open with Hibernate's comment |
| C1 | bare agent: lazy loads get `java_jpa` |
| C2 | bare agent: the commented derived SELECT gets `java_jpa` |
| C3 | bare agent: the commented bulk UPDATE gets `java_generic` |
| C4 | bare agent: the JdbcTemplate SELECT gets `java_generic` |
| M0 | micrometer: every span sits under `org.springframework.boot`, none carries `code.namespace`, none is a database span |
| M1 | micrometer: `n_plus_one_http` gets `java_generic` |
| D1 | the daemon, fed by the agent directly, gives lazy loads `java_jpa` |
| P1 | the agent file and the daemon agree on every finding signature |

A0, C0 and M0 guard the premise. Should an agent release start wrapping lazy
loads in a Hibernate span, A0 fails rather than let A1 pass for the old reason.

Run against 0.25.2 the scenario fails A1, C1, C2, M1 and D1 (`java_generic`,
and no fix at all on M1), and passes the other nine.

## The fixture

`fixtures/` is one Spring Boot 4.1.1 application on an in-memory H2, seeded by
H2 itself on connect so the seed emits no JDBC span. On startup it calls its
own `GET /work` once through the JDK client. `/work` runs five loops of six
calls: the lazy `books` collection of each author, a hand-written
`select id, title from book where author_id = ?` through JdbcTemplate, the
derived query `findByTitle`, the bulk JPQL `update Book b set b.title = ?2
where b.id = ?1`, and `GET /api/ping/{id}` through RestClient. The app then
exits, which flushes the exporter.

The default profile has no tracing dependency: the OTel Java agent, which the
build copies to `target/`, is attached at run time. The `micrometer` profile
adds `spring-boot-starter-opentelemetry`, which traces the RestClient calls
but no JDBC statement. `census.py` holds the parsers the assertions share.

## Run

```bash
cargo build --release   # in the perf-sentinel checkout
make verify-hibernate-alias-suggestion
```

Needs the local release binary, JDK 25, Maven and python3. No cluster. Around a
minute once Maven has its dependencies. `PERF_SENTINEL_LOCAL_BIN` points at
another binary, which is how the 0.25.2 control above runs.

## Watch out

**The detector type of a loop moves between runs.** Every statement here is
already parameterized, so the strict sanitizer-aware mode turns a repeated
group into `n_plus_one_sql` or leaves it `redundant_sql` depending on the
spread of its durations, which differs from one run of the app to the next.
The type is part of the signature, so two captures can disagree on it. The
assertions find each loop by its template for that reason. On one capture,
0.25.2 and 0.25.3 produce the same signatures.
