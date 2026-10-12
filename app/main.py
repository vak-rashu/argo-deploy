import asyncio
import json
import os
import random
import time
import uuid
from typing import Any, Dict, List, Optional

from fastapi import FastAPI, Header, Query, Request, Response, status
from fastapi.responses import JSONResponse, StreamingResponse
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from pydantic import BaseModel, Field

# -------------------------------------------------------------------------
# Environment & Configuration
# -------------------------------------------------------------------------
APP_VERSION = os.getenv("APP_VERSION", "v1")
PORT = int(os.getenv("PORT", "8000"))
BASE_TTFT_MS = float(os.getenv("BASE_TTFT_MS", "80.0"))
BASE_TOKEN_DELAY_MS = float(os.getenv("BASE_TOKEN_DELAY_MS", "15.0"))
SIMULATE_DEGRADED = os.getenv("SIMULATE_DEGRADED", "false").lower() in ("true", "1", "yes")
ERROR_RATE = float(os.getenv("ERROR_RATE", "0.5" if SIMULATE_DEGRADED else "0.0"))
INDUCED_LATENCY_MS = float(os.getenv("INDUCED_LATENCY_MS", "1200.0" if SIMULATE_DEGRADED else "0.0"))

START_TIME = time.time()

# -------------------------------------------------------------------------
# Prometheus Metrics
# -------------------------------------------------------------------------
HTTP_REQUESTS_TOTAL = Counter(
    "http_requests_total",
    "Total count of HTTP requests processed",
    ["method", "path", "status"],
)

LLM_ACTIVE_REQUEST_QUEUE = Gauge(
    "llm_active_request_queue",
    "Current number of concurrent active inference requests in flight",
)

LLM_TIME_TO_FIRST_TOKEN_SECONDS = Histogram(
    "llm_time_to_first_token_seconds",
    "Time taken to generate the first token (TTFT) in seconds",
    buckets=(0.05, 0.1, 0.2, 0.35, 0.5, 0.75, 1.0, 1.5, 2.0, 5.0),
)

# -------------------------------------------------------------------------
# FastAPI Application
# -------------------------------------------------------------------------
app = FastAPI(
    title="Lightweight LLM Inference Engine",
    description="High-fidelity simulation of an LLM inference service (vLLM/Ollama compatible) for Kubernetes GitOps & MLOps.",
    version=APP_VERSION,
)


class ChatMessage(BaseModel):
    role: str = "user"
    content: str = ""


class ChatCompletionRequest(BaseModel):
    model: str = "mock-llm-7b"
    messages: List[ChatMessage] = Field(default_factory=lambda: [ChatMessage(role="user", content="Hello")])
    stream: bool = True
    max_tokens: Optional[int] = 20
    temperature: Optional[float] = 0.7


@app.get("/healthz")
@app.get("/readyz")
@app.get("/livez")
async def health_check():
    """Liveness & readiness probe endpoint."""
    return {
        "status": "healthy",
        "version": APP_VERSION,
        "uptime_seconds": round(time.time() - START_TIME, 2),
        "degraded_mode": SIMULATE_DEGRADED,
    }


@app.get("/metrics")
async def metrics():
    """Exposes Prometheus scrape metrics."""
    return Response(content=generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.post("/v1/chat/completions")
async def chat_completions(
    request: Request,
    body: Optional[ChatCompletionRequest] = None,
    simulate_error: Optional[bool] = Query(None, description="Force HTTP 500 error"),
    simulate_latency_ms: Optional[float] = Query(None, description="Force extra latency in ms"),
    x_simulate_error: Optional[str] = Header(None, alias="X-Simulate-Error"),
    x_simulate_high_latency: Optional[str] = Header(None, alias="X-Simulate-High-Latency"),
):
    """
    Simulates streaming LLM token generation with customizable latency,
    concurrency queue tracking, and metric instrumentation.
    """
    req_start = time.time()
    LLM_ACTIVE_REQUEST_QUEUE.inc()

    try:
        # Determine error simulation triggers
        should_fail = False
        if simulate_error is True or (x_simulate_error and x_simulate_error.lower() in ("true", "1")):
            should_fail = True
        elif ERROR_RATE > 0.0 and random.random() < ERROR_RATE:
            should_fail = True

        if should_fail:
            HTTP_REQUESTS_TOTAL.labels(method="POST", path="/v1/chat/completions", status="500").inc()
            return JSONResponse(
                status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
                content={
                    "error": {
                        "message": "Simulated LLM serving engine GPU OOM / CUDA error.",
                        "type": "server_error",
                        "code": 500,
                        "version": APP_VERSION,
                    }
                },
            )

        # Determine latency simulation
        extra_latency_ms = 0.0
        if simulate_latency_ms is not None:
            extra_latency_ms = simulate_latency_ms
        elif x_simulate_high_latency and x_simulate_high_latency.lower() in ("true", "1"):
            extra_latency_ms = 1200.0
        elif INDUCED_LATENCY_MS > 0:
            extra_latency_ms = INDUCED_LATENCY_MS

        ttft_delay_seconds = (BASE_TTFT_MS + extra_latency_ms) / 1000.0

        # Simulate TTFT (Prefill phase)
        await asyncio.sleep(ttft_delay_seconds)
        ttft_actual = time.time() - req_start
        LLM_TIME_TO_FIRST_TOKEN_SECONDS.observe(ttft_actual)

        chat_id = f"chatcmpl-{uuid.uuid4().hex[:12]}"
        tokens = [
            "Kubernetes", " GitOps", " with", " Argo", " Rollouts",
            " and", " KEDA", " provides", " resilient", " autoscaling",
            " for", " production", " LLM", " workloads."
        ]

        # Check streaming mode
        is_stream = body.stream if body else True

        if is_stream:
            async def event_generator():
                try:
                    for i, tok in enumerate(tokens):
                        chunk = {
                            "id": chat_id,
                            "object": "chat.completion.chunk",
                            "created": int(time.time()),
                            "model": body.model if body else "mock-llm-7b",
                            "version": APP_VERSION,
                            "choices": [
                                {
                                    "index": 0,
                                    "delta": {"content": tok},
                                    "finish_reason": "stop" if i == len(tokens) - 1 else None,
                                }
                            ],
                        }
                        yield f"data: {json.dumps(chunk)}\n\n"
                        await asyncio.sleep(BASE_TOKEN_DELAY_MS / 1000.0)
                    yield "data: [DONE]\n\n"
                finally:
                    LLM_ACTIVE_REQUEST_QUEUE.dec()
                    HTTP_REQUESTS_TOTAL.labels(
                        method="POST", path="/v1/chat/completions", status="200"
                    ).inc()

            return StreamingResponse(event_generator(), media_type="text/event-stream")
        else:
            # Non-streaming mode
            for _ in tokens:
                await asyncio.sleep(BASE_TOKEN_DELAY_MS / 1000.0)
            
            LLM_ACTIVE_REQUEST_QUEUE.dec()
            HTTP_REQUESTS_TOTAL.labels(
                method="POST", path="/v1/chat/completions", status="200"
            ).inc()

            return {
                "id": chat_id,
                "object": "chat.completion",
                "created": int(time.time()),
                "model": body.model if body else "mock-llm-7b",
                "version": APP_VERSION,
                "choices": [
                    {
                        "index": 0,
                        "message": {"role": "assistant", "content": "".join(tokens)},
                        "finish_reason": "stop",
                    }
                ],
                "usage": {
                    "prompt_tokens": 8,
                    "completion_tokens": len(tokens),
                    "total_tokens": 8 + len(tokens),
                },
                "metrics": {
                    "time_to_first_token_sec": round(ttft_actual, 4),
                    "total_latency_sec": round(time.time() - req_start, 4),
                },
            }

    except Exception as e:
        LLM_ACTIVE_REQUEST_QUEUE.dec()
        HTTP_REQUESTS_TOTAL.labels(
            method="POST", path="/v1/chat/completions", status="500"
        ).inc()
        raise e
