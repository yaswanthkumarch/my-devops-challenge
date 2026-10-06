"""Minimal tests for the greeting service."""
from app.main import app


def test_hello():
    client = app.test_client()
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json["message"] == "Hello, Candidate"


def test_healthz():
    client = app.test_client()
    resp = client.get("/healthz")
    assert resp.status_code == 200


def test_readyz():
    client = app.test_client()
    resp = client.get("/readyz")
    assert resp.status_code == 200


def _extract_http_total(metrics_text, route="/"):
    """Return the value of http_requests_total for the route, or None."""
    for line in metrics_text.splitlines():
        if line.startswith("http_requests_total{") and f'path="{route}"' in line:
            return float(line.rsplit(" ", 1)[1])
    return None


def test_metrics_counts_and_increments():
    client = app.test_client()

    first = _extract_http_total(client.get("/metrics").get_data(as_text=True))
    assert first is not None, "http_requests_total missing after requests"

    client.get("/")
    second = _extract_http_total(client.get("/metrics").get_data(as_text=True))
    assert second == first + 1


def test_metrics_path_label_is_route_not_raw_path():
    client = app.test_client()
    client.get("/not-a-real-route")
    text = client.get("/metrics").get_data(as_text=True)
    # The unmatched path must appear as the "unmatched" route label, never as
    # a per-path label (cardinality control).
    assert 'path="/not-a-real-route"' not in text
    assert 'path="unmatched"' in text
