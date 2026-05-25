# fastapi-svc Dockerfile. Single-stage (python slim for asyncpg binary).
# Build with:  docker build -t fastapi-svc:s1 services/fastapi-svc

FROM python:3.14-slim-bookworm

RUN useradd -r -u 65532 -d /app nonroot
WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app

EXPOSE 8092
USER 65532:65532

ENV PYTHONDONTWRITEBYTECODE=1
CMD uvicorn app.main:app \
    --host 0.0.0.0 --port ${HTTP_PORT:-8092} \
    --workers 2 --timeout-keep-alive 120
