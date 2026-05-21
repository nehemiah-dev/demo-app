"""
FastAPI demo app — instrumented with OpenTelemetry.
Emits traces to Tempo via OTel Collector, logs to Loki via OTel Collector,
and exposes Prometheus metrics via prometheus-fastapi-instrumentator.
"""

import logging
import random
import time

from fastapi import FastAPI, HTTPException
from opentelemetry import trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_fastapi_instrumentator import Instrumentator

# ── Shared resource ───────────────────────────────────────────────────────────
resource = Resource.create({"service.name": "demo-app", "service.version": "1.0.0"})

# ── Tracing setup ─────────────────────────────────────────────────────────────
tracer_provider = TracerProvider(resource=resource)
otlp_trace_exporter = OTLPSpanExporter(endpoint="http://localhost:4317", insecure=True)
tracer_provider.add_span_processor(BatchSpanProcessor(otlp_trace_exporter))
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer("demo-app")

# ── Logging setup ─────────────────────────────────────────────────────────────
logger_provider = LoggerProvider(resource=resource)
set_logger_provider(logger_provider)
otlp_log_exporter = OTLPLogExporter(endpoint="http://localhost:4317", insecure=True)
logger_provider.add_log_record_processor(BatchLogRecordProcessor(otlp_log_exporter))

# Injects trace_id and span_id into log records
LoggingInstrumentor().instrument(set_logging_format=False)

logging.basicConfig(
    level=logging.INFO,
    format='{"time":"%(asctime)s","level":"%(levelname)s","logger":"%(name)s","message":"%(message)s","trace_id":"%(otelTraceID)s","span_id":"%(otelSpanID)s"}',
)

# Attach OTel log handler so logs are forwarded to Loki via the collector
otel_handler = LoggingHandler(level=logging.INFO, logger_provider=logger_provider)
logging.getLogger().addHandler(otel_handler)

log = logging.getLogger("demo-app")

# ── App ───────────────────────────────────────────────────────────────────────
app = FastAPI(title="LGTM Demo App", version="1.0.0")

Instrumentator().instrument(app).expose(app)
FastAPIInstrumentor.instrument_app(app)


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/")
def root():
    log.info("root endpoint hit")
    return {"status": "ok", "service": "demo-app"}


@app.get("/items/{item_id}")
def get_item(item_id: int):
    with tracer.start_as_current_span("db.query") as span:
        span.set_attribute("db.system", "postgresql")
        span.set_attribute("db.statement", f"SELECT * FROM items WHERE id={item_id}")
        latency = random.uniform(0.01, 0.15)
        time.sleep(latency)
        if item_id > 900:
            log.warning("item_id out of range", extra={"item_id": item_id})
            raise HTTPException(status_code=404, detail="Item not found")
    log.info("item fetched", extra={"item_id": item_id, "latency_ms": round(latency * 1000, 2)})
    return {
        "item_id": item_id,
        "name": f"Item {item_id}",
        "latency_ms": round(latency * 1000, 2),
    }


@app.get("/slow")
def slow_endpoint():
    with tracer.start_as_current_span("slow.operation") as span:
        delay = random.uniform(0.5, 2.0)
        span.set_attribute("simulated.delay_ms", round(delay * 1000))
        time.sleep(delay)
    log.warning("slow response", extra={"delay_ms": round(delay * 1000, 2)})
    return {"status": "slow", "delay_ms": round(delay * 1000, 2)}


@app.get("/error")
def error_endpoint():
    log.error("simulated application error")
    raise HTTPException(status_code=500, detail="Simulated server error")


@app.get("/health")
def health():
    return {"status": "healthy"}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
