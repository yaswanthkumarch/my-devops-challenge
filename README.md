# Skybyte API

A small Python service that returns a greeting. Runs in Kubernetes via Helm.

> **Note:** the engineer who set this up is no longer with the team. The
> challenge brief is in [`CHALLENGE.md`](./CHALLENGE.md). The inherited repo
> was audited and hardened — see [`AUDIT.md`](./AUDIT.md) for every defect
> found and [`DECISIONS.md`](./DECISIONS.md) for the reasoning behind each
> fix.

## What was wrong (and what changed)

The inherited repo *worked* while being unsafe to ship: the image was an
unpinned, EOL `python:3.9` running the Flask **dev server as root** (no
`USER`, no gunicorn); the Helm chart had **no securityContext, no resource
requests/limits, and both probes pointed at the business endpoint `/`** with
default thresholds; a live-looking **API token sat in plaintext in both
`values.yaml` and `terraform/variables.tf`**; and the CI pipeline was
theater — flake8 excluded the directory it linted and ran with `--exit-zero`,
helm lint and terraform validate were suffixed `|| true`, and no tests,
manifest validation, image scanning, or policy checks ran at all. Meanwhile
the README claimed a non-root `appuser` that never existed. Hardening closed
all of it: digest-pinned slim base, UID 10001, gunicorn with a 20s SIGTERM
drain inside a 30s grace period, route-normalized Prometheus metrics,
split liveness/readiness endpoints, Terraform-owned secret consumed by
reference, enforced securityContext, two Kyverno policies with negative
test fixtures, and a CI that can actually fail.

## Prerequisites

Versions below are what this is written against; to be confirmed after a
full end-to-end run:

- Docker Desktop / engine (tested: 4.30+ / API 1.45)
- kind 0.23+ or Minikube 1.33+ (local cluster)
- kubectl 1.30+ (matching cluster minor)
- Helm 3.14+
- Terraform 1.5+ (`>= 1.5, < 2.0` pinned in `terraform/versions.tf`)
- Python 3.12 (matching the image base) for local tests
- kyverno CLI 1.12+ and kubeconform 0.6+ only if running those gates locally
  (CI installs its own)

## SLO

> **99% of requests to `/` complete in under 50 ms over a rolling 7-day
> window.**

The handler does no I/O — it serializes a constant JSON document — so 50 ms
is ~10x headroom over typical single-digit-millisecond server latency, and
it deliberately matches the `le="0.05"` histogram bucket so compliance is a
single Prometheus ratio. **Knowing if it broke:** a burn-rate alert pairs a
fast window with a slow one — fast path when ~2% of the weekly budget burns
within 1 hour (5m and 1h ratios both below 99%), slow path on sustained
burn (6h/3d) — reading
`rate(http_requests_duration_seconds_bucket{path="/",le="0.05"}[w]) /
rate(...{path="/",le="+Inf"}[w])`. The 50 ms boundary is engineering
judgment, not load-test data; a `k6` pass against a kind cluster is on the
follow-up list.

## Quick start

```bash
./setup.sh          # build, load into kind/minikube, terraform apply, helm upgrade --install
./system-checks.sh  # verify: UID non-root, caps, / body, /metrics, pod-kill recovery
```

The secret value is read from `TF_VAR_api_token` (export it for anything
non-local); `setup.sh` falls back to a throwaway local-only value.

To verify the deployment manually:

```bash
kubectl -n devops-challenge get pods
kubectl -n devops-challenge port-forward svc/skybyte-app 8080:80
curl http://localhost:8080/
# expected: {"message": "Hello, Candidate", "version": "1.0.0"}
```

## Architecture

```
[Client] ──► [Service:80] ──► [Pod UID 10001:8080]
                                   │
                                   ├── /          business endpoint (JSON)
                                   ├── /healthz   liveness (dependency-free)
                                   ├── /readyz    readiness
                                   └── /metrics   Prometheus (http_requests_total,
                                                  request duration histogram)
```

The pod runs as UID 10001 with a read-only root filesystem, all capabilities
dropped, `RuntimeDefault` seccomp, and a writable `emptyDir` at `/tmp`.
Gunicorn is PID 1: SIGTERM stops new connections and drains in-flight
requests for up to 20s inside the 30s termination grace period.

## CI

GitHub Actions runs ruff, pytest (including the metrics contract), helm
lint, `helm template | kubeconform`, `terraform fmt -check` + validate,
multi-arch buildx (amd64+arm64), Trivy fs + image scans failing on
HIGH/CRITICAL, and the Kyverno policies against rendered manifests plus
negative fixtures. See `.github/workflows/ci.yml`.

## Layout

```
/
├── app/                  Python service (gunicorn + prometheus_client)
├── policies/             Kyverno policies (non-root baseline, requests+limits)
├── test/                 bad-manifest fixtures, each failing exactly one policy
├── terraform/            Namespace + ResourceQuota + secret (sensitive var)
├── helm/skybyte-app/     Helm chart
├── .github/workflows/    CI
├── setup.sh
├── system-checks.sh
├── AUDIT.md              every defect found, with fix status
├── DECISIONS.md          the reasoning you'll be asked about
└── CHALLENGE.md          ← the original brief
```

## Things I would do next with another week

Deliberately cut from this pass, most valuable first:

1. **Replicas ≥ 2 + PodDisruptionBudget** — the single replica means every
   pod restart is an outage window; the probe tuning papers over it instead
   of fixing it. Cut because it doubles the resource footprint of the demo
   and touches the quota math.
2. **Load test to validate the SLO's 50 ms** — the N is judgment, not
   measurement; a k6/hey run against kind would replace "defensible" with
   "observed".
3. **Pin GitHub Actions to commit SHAs** — major-tag pins (`@v4`) are
   mutable upstream; a supply-chain gap in an otherwise hardened pipeline.
4. **Sealed Secrets / External Secrets Operator** — removes the
   plaintext-in-TF-state tradeoff that the Terraform-owns-secret decision
   accepted.
5. **Remote TF state (S3 + locking) with encryption** — currently local
   file state, single-reader.
6. **Helm-managed ServiceMonitor with prometheus-operator schemas in
   kubeconform** — only if the target cluster standardizes on
   kube-prometheus-stack; annotations remain the portable default.
7. **NetworkPolicies** (default-deny ingress except from ingress/S-Scraper)
   — nothing in the brief demanded it, and it's the kind of addition that
   needs real traffic patterns to get right.
8. **Image signing (cosign) + SBOM attestation** in the multi-arch build.
9. **A third policy: `readOnlyRootFilesystem` enforced by Kyverno** —
   currently only the chart sets it; policy would catch a regression, but
   two policies + fixtures already cover the brief's minimum and I preferred
   depth on those over breadth here.
