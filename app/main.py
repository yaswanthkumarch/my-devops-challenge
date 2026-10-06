"""Skybyte greeting service.

Served by gunicorn (see gunicorn.conf.py) so SIGTERM stops new connections and
drains in-flight requests; never run via app.run() in the container.
"""
import os
import time

from flask import Flask, Response, g, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    Counter,
    Histogram,
    generate_latest,
)

app = Flask(__name__)

VERSION = "1.0.0"
# Kept to exercise the Terraform -> kubernetes_secret -> env delivery path.
# No handler uses it today; removing the plumbing would break that contract.
API_TOKEN = os.environ.get("API_TOKEN", "")

# path label is the ROUTE PATTERN (request.url_rule), never the raw path:
# raw paths (query strings, ids, 404 scans) would explode Prometheus label
# cardinality. Anything that doesn't match a route counts under "unmatched".
REQUEST_COUNT = Counter(
    "http_requests_total",
    "Total HTTP requests",
    ["method", "path", "status"],
)
REQUEST_LATENCY = Histogram(
    "http_requests_duration_seconds",
    "HTTP request latency in seconds",
    ["path"],
    # le=0.05 is the SLO bucket: the README SLO (p99 < 50ms for "/") is read
    # straight off this boundary — no re-metric needed if the target moves.
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5),
)


@app.before_request
def _start_timer():
    g.start_time = time.perf_counter()


@app.after_request
def _record_metrics(response):
    route = request.url_rule.rule if request.url_rule is not None else "unmatched"
    REQUEST_COUNT.labels(request.method, route, response.status_code).inc()
    start = g.get("start_time")
    if start is not None:
        REQUEST_LATENCY.labels(route).observe(time.perf_counter() - start)
    return response


@app.route("/")
def hello():
    return jsonify({"message": "Hello, Candidate", "version": VERSION})


@app.route("/healthz")
def healthz():
    # Liveness: "the process is not wedged". Must stay dependency-free so a
    # broken downstream cannot cascade into restarts.
    return jsonify({"status": "ok"}), 200


@app.route("/readyz")
def readyz():
    # Readiness: "safe to send me traffic now". Separate endpoint from
    # /healthz so dependency checks can be added here without the risk of
    # liveness restarts.
    return jsonify({"status": "ready"}), 200


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)
