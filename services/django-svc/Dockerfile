# django-svc multistage Dockerfile.
#
#   1. python:3.14-slim-bookworm builder: pip install + collectstatic.
#   2. Same slim image as runtime (distroless python3 lacks pip and
#      psycopg binary deps — slim-bookworm is the pragmatic choice for
#      Django + psycopg[binary]).
#
# Build with:  docker build -t django-svc:s1 services/django-svc

FROM python:3.14-slim-bookworm AS builder
WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY djangosvc ./djangosvc

FROM python:3.14-slim-bookworm

RUN useradd -r -u 65532 -d /app nonroot
WORKDIR /app

COPY --from=builder /usr/local/lib/python3.14/site-packages /usr/local/lib/python3.14/site-packages
COPY --from=builder /usr/local/bin/gunicorn /usr/local/bin/gunicorn
COPY --from=builder /app /app

EXPOSE 8091
USER 65532:65532

CMD ["gunicorn", "djangosvc.wsgi:application", \
     "--bind", "0.0.0.0:8091", \
     "--workers", "2", \
     "--threads", "4", \
     "--timeout", "120"]
