# Quarkus multistage Dockerfile. Three stages, mirroring the
# services/shared-dockerfile/Dockerfile pattern used by the Spring
# Boot baseline:
#   1. Maven build with Eclipse Temurin JDK 25 (build-only Temurin,
#      runtime is OpenJDK distroless — see docs/MULTISTACK.md
#      "Stack-specific release notes / Helidon 4.4.0" comment which
#      applies identically to Quarkus).
#   2. Runtime image gcr.io/distroless/java25:nonroot. quarkus-fast-jar
#      layout is copied as-is; the OTel SDK is built into the app via
#      the quarkus-opentelemetry extension, no agent volume to mount.
#
# Build with:
#   docker build -t quarkus-svc:s2 services/quarkus-svc

# ---- builder ----
FROM eclipse-temurin:25-jdk-alpine AS builder

WORKDIR /build
COPY pom.xml /build/pom.xml
# Pre-fetch dependencies so layer cache stays warm across source edits.
# `go-offline` is best-effort; the next `package` run still resolves.
RUN apk add --no-cache maven && \
    mvn -B -ntp dependency:go-offline -DskipTests || true

COPY src /build/src
RUN mvn -B -ntp package -DskipTests -Dquarkus.package.jar.type=fast-jar

# ---- runtime ----
FROM gcr.io/distroless/java25:nonroot

# quarkus-fast-jar layout: target/quarkus-app/{quarkus-run.jar,lib,quarkus,app}
COPY --from=builder /build/target/quarkus-app/ /app/

EXPOSE 8083

# UID 65532 is the distroless `nonroot` user. Matches the Java baseline
# pod spec (services/order-service/helm/templates/deployment.yaml).
USER 65532:65532

WORKDIR /app
ENTRYPOINT ["java", "-jar", "/app/quarkus-run.jar"]
