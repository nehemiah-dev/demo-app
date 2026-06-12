# ObserveX

A FastAPI app instrumented with OpenTelemetry to demonstrate traces, logs, and metrics.

## What it does

- Exposes a few endpoints (`/`, `/items/{item_id}`, `/slow`, `/error`, `/health`) that simulate normal, slow, and error responses.
- Emits **traces** (including custom spans) and **logs** via OTLP/gRPC to an OpenTelemetry Collector on `localhost:4317`.
- Injects trace/span IDs into logs for trace-log correlation.
- Exposes Prometheus-compatible **metrics** at `/metrics`.

## Tools used

- **FastAPI** + **Uvicorn** — web framework/server
- **OpenTelemetry SDK** — tracing and logging instrumentation
- **OTLP gRPC exporter** — sends traces/logs to a collector
- **prometheus-fastapi-instrumentator** — exposes Prometheus metrics
- **OpenTelemetry Collector** (Docker) — receives telemetry (e.g. `debug` exporter, or forwards to Tempo/Loki/Prometheus)

## Running locally

1. Create and activate a virtualenv, then install dependencies:
   ```bash
   python -m venv venv
   source venv/bin/activate
   pip install -r requirements.txt
   ```

   ```

2. Run the app:
   ```bash
   uvicorn main:app --host 0.0.0.0 --port 8080
   ```

3. Try the endpoints:
   ```bash
   curl http://localhost:8080/
   curl http://localhost:8080/items/5
   curl http://localhost:8080/slow
   curl http://localhost:8080/error
   curl http://localhost:8080/metrics
   ```

Without a collector running, the app still works — exports will just fail/retry silently in the background.