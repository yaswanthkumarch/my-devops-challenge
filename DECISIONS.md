# DECISIONS.md

One block per meaningful choice, in the format the challenge requires.
Constraint-specific reasoning only — where a cost was knowingly accepted, it
is named.

### Decision: Base image — slim, digest-pinned, not distroless
**Context:** S-1/S-2: the inherited `python:3.9` is unpinned, non-minimal, and
EOL; the brief allows slim or distroless.
**Options considered:** (a) `python:3.12-slim-bookworm` pinned by digest —
Debian userspace, pip-native builds, shell present; (b) `gcr.io/distroless/python312`
— minimal surface but no shell, no pip, exec-based debugging only.
**Chosen:** (a), `python:3.12-slim-bookworm@sha256:34386ef0cb...` (digest
fetched live from the Docker Hub registry at fix time).
**Rationale:** `system-checks.sh` steps 1–2 `exec` into the pod and read
`/proc` (`id -u`, `CapEff` of PID 1) — those need a shell. Distroless would
force rewriting the verification story (ephemeral debug containers) for a
surface saving that matters more at fleet scale than in a single-service
challenge; slim keeps one build stage, no builder/runtime dance to defend.
**Cost / risk you accepted:** Debian userspace is bigger than distroless, so
more CVE surface for Trivy to flag over time; accepted because digest-pinning
plus a cheap rebuild loop is the working mitigation.

### Decision: Secret owner — Terraform, not Helm
**Context:** the token sat in plaintext in `values.yaml` AND as a TF variable
default (two sources of truth that already disagree with the design); the
brief says pick one owner.
**Options considered:** (a) Terraform `kubernetes_secret` with a sensitive
variable, Helm consumes by reference; (b) Helm-managed secret via
`--set-string` / `--create` with values injected at deploy time.
**Chosen:** (a).
**Rationale:** the namespace, quota, and secret are a provisioning unit that
outlives any single release; TF already owns the other two, so a second owner
for the third object guarantees drift — the starter repo itself is the proof
(the same token in two files). Helm releases get replaced and rolled back;
the secret must not follow that lifecycle.
**Cost / risk you accepted:** the token is plaintext in `terraform.tfstate`.
Mitigations if this left the challenge: remote state (S3/GCS) with
encryption + restricted IAM + state locking; or move to ExternalSecrets/
SealedSecrets entirely. Accepted here because a local file state has exactly
one reader — me.

### Decision: Prometheus discovery — Service annotations, not ServiceMonitor
**Context:** observability requirement; the brief asks for one and to state
the kubeconform CRD-schema implication.
**Options considered:** (a) `prometheus.io/*` annotations on the Service —
plain core-v1 metadata, validated by kubeconform's built-in schemas; (b) a
`ServiceMonitor` — first-class prometheus-operator object, stronger typing,
but a CRD.
**Chosen:** (a).
**Rationale:** kubeconform validates core resources against built-in schemas;
with a ServiceMonitor, CI either needs the prometheus-operator CRD schemas
fetched as an extra `-schema-location` (a supply-chain dependency to pin and
maintain) or `-ignore-missing-schemas` — which silently disables validation
for *any* unknown kind, i.e. a hole punched in exactly the gate this challenge
is about. The chart is meant to run against any local cluster, CRD optional.
**Cost / risk you accepted:** annotations are just strings — no schema
protection against typos (`promethus.io` renders fine and scrapes nothing),
and consumption depends on the Prometheus install's scrape config having the
annotation-based job enabled. Flagged in AUDIT.md "Verify locally" #3.

### Decision: Kyverno over Gatekeeper for policy-as-code
**Context:** two admission policies must exist and must run both in-cluster
and in CI against rendered manifests.
**Options considered:** (a) Kyverno — YAML patterns, `kyverno apply` CLI
ships with the same tool; (b) Gatekeeper/OPA — Rego constraints, more
expressive, heavier install.
**Chosen:** (a).
**Rationale:** both policies I need ("no root", "requests+limits exist") are
structural matches — Kyverno's `anyPattern`/`pattern` express them in the
same YAML the team reviews in the Helm chart, and the *one* CLI (`kyverno
apply`) validates both rendered manifests and negative fixtures in CI with no
cluster needed. Gatekeeper's power (cross-object Rego, mutation library) is
unused by these two policies and would add an OPA dependency plus a language
nobody else on a small team reads daily.
**Cost / risk you accepted:** Rego-class logic (e.g. "limit must exceed
request", cross-referencing quotas) is awkward or impossible in Kyverno
patterns; if policies grow that way, expect a re-evaluation.

### Decision: path label = route pattern, 404s bucketed as "unmatched"
**Context:** the metrics brief demands a `path` label; raw request paths are
a cardinality trap.
**Options considered:** (a) `request.url_rule.rule` (Flask's matched route
pattern), falling back to the constant `"unmatched"`; (b) `request.path` —
exact per-URL labels; (c) no path label at all.
**Chosen:** (a).
**Rationale:** every distinct URL becomes a distinct time series in
`http_requests_total{path=...}`; one URL scanner hitting `/foo?page=N`
manufactures thousands of series, which is memory in the Prometheus TSDB and
CPU in every scrape — for zero analytical gain over the route pattern. The
`"unmatched"` bucket keeps 404 noise visible (one series) instead of absent.
Test `test_metrics_path_label_is_route_not_raw_path` pins this contract.
**Cost / risk you accepted:** can't slice latency by *specific* broken URL
(e.g. one pathological `/orders/123`); if per-URL debugging is needed, that
belongs in access logs with sampling, not in the metrics path label.

### Decision: Probe numbers (and why each one)
**Context:** both probes pointed at `/` with all-default thresholds; liveness
killing the pod for business-path slowness was the failure mode.
**Options considered:** (a) keep defaults (`periodSeconds: 10`,
`timeoutSeconds: 1`, `failureThreshold: 3`) but on the new endpoints;
(b) tuned values per endpoint role.
**Chosen:** liveness `/healthz`: `initialDelaySeconds: 10, periodSeconds: 10,
timeoutSeconds: 2, failureThreshold: 3`; readiness `/readyz`:
`initialDelaySeconds: 5, periodSeconds: 5, timeoutSeconds: 2,
failureThreshold: 3`.
**Rationale:** `initialDelay 10` — gunicorn boot is ~1s; 10x covers cold-page
first touches without masking a genuinely wedged start. `timeout 2` — the
handler is in-process, sub-millisecond; 2s is ~1000x headroom, and the
default 1s is tight enough to flap under transient CPU steal. Liveness
`failureThreshold 3` × `period 10` — a real wedge costs ≤30s to detect; a
single slow probe never kills. Readiness `period 5` — recovering pods rejoin
rotation within ~5s; `initialDelay 5` — readiness gates before liveness so a
not-yet-listening socket is "not ready", not "dead".
**Cost / risk you accepted:** a wedged process is restarted up to ~30s later
than with aggressive numbers; on a 1-replica service that's 30s of outage
per wedge — the fix is replicas ≥ 2, not meaner probes (deliberately not
added: replicaCount is part of the sizing decision, not the probe one).

### Decision: No preStop hook
**Context:** brief says preStop only if justified; the drain path had to be
designed end-to-end.
**Options considered:** (a) `preStop: sleep 5` — classic "wait for endpoint
propagation before SIGTERM"; (b) no preStop, rely on gunicorn's SIGTERM
drain.
**Chosen:** (b), with `terminationGracePeriodSeconds: 30` and
`graceful_timeout: 20`.
**Rationale:** gunicorn's SIGTERM handler already stops accepting
connections and drains in-flight requests — the sleep adds nothing for an
HTTP-only, keepalive-bounded, 1-replica service whose load balancing comes
from Service endpoints. The endpoint-propagation race preStop mitigates
matters when long-lived connections (websockets/SSE) or client-side
connection pools pin traffic to a dying pod; neither exists here.
**Cost / risk you accepted:** during propagation delay (~1s typical), a
request routed to the dying pod can still 502; if that shows up in practice,
the one-line preStop sleep is the first lever — this is a recorded trigger
condition, not an oversight.

### Decision: Port 8080, Service stays 80
**Context:** S-2/S-9 conflict: non-root + drop ALL capabilities makes binding
port 80 impossible; the chart, Service, and README all assumed 80.
**Options considered:** (a) keep 80 and add back `CAP_NET_BIND_SERVICE`;
(b) move the container to 8080, keep the Service's external port at 80.
**Chosen:** (b).
**Rationale:** (a) reopens exactly the capability surface the hardening
closed and adds a per-container exception that the "drop ALL" policy cannot
express; (b) costs nothing — `targetPort: http` is already indirection, and
clients of the Service never see the change.
**Cost / risk you accepted:** the container port is now 8080 everywhere
(probes, annotations, EXPOSE) — a reader must hold that mapping in mind;
documented in values.yaml and the README architecture line.

### Decision: ResourceQuota widened to all four dimensions
**Context:** the inherited quota tracked only `limits.memory`, while the
chart shipped no limits — the two halves contradicted and pod creation was
rejected at admission.
**Options considered:** (a) keep memory-only quota, chart sets limits.memory;
(b) quota covers requests.cpu/memory + limits.cpu/memory, chart declares all
four.
**Chosen:** (b).
**Rationale:** a quota key is an admission gate: any pod in the namespace
that omits that key is rejected. With (a), CPU stayed unbounded per pod and
"the chart must declare resources" lived only in a README wish; with (b),
Kubernetes itself enforces what the Kyverno requests-limits policy also
enforces — defense in depth from two independent layers.
**Cost / risk you accepted:** every future workload in this namespace must
declare all four values or be rejected — that friction is the point, but it
will surprise the next person who applies a plain manifest.

### Decision: SLO threshold — p99 under 50 ms for `/`
**Context:** the brief requires one SLO sentence with a defensible N.
**Options considered:** (a) N=50ms; (b) N=100ms; (c) N=10ms.
**Chosen:** (a) — "99% of requests to `/` complete in under 50 ms over a
rolling 7-day window."
**Rationale:** the handler serializes a constant JSON dict — no I/O, no DB —
so observed server-side latency is dominated by process scheduling, GC
pauses, and kube-proxy hop: low single-digit milliseconds typically. 50ms
gives ~10x headroom above that while still catching real degradation
(CPU-throttling from misconfigured limits, node pressure); 10ms would page
on ordinary jitter, 100ms wouldn't page until the service is effectively
down. The histogram bucket `le="0.05"` matches the SLO boundary exactly, so
the compliance query is one ratio over one bucket.
**Cost / risk you accepted:** the N is engineering judgment, not measured
load-test data — the honest caveat is in the README with the load-test
follow-up; alerting on a 7-day window alone reacts slowly, so the alert
pairing below is burn-rate based.

### Decision: SLO breach alerting — burn-rate, not raw ratio
**Context:** "how you'd know if it broke" — a 7-day window evaluated nightly
is too slow to act on.
**Options considered:** (a) alert when the 7-day compliance ratio < 99%;
(b) multi-window burn-rate (fast: 5m vs 1h; slow: 6h vs 3d); (c) page on any
p99 > 50ms in 5 minutes.
**Chosen:** (b), reading
`rate(http_requests_duration_seconds_bucket{path="/",le="0.05"}[w]) /
rate(http_requests_duration_seconds_bucket{path="/",le="+Inf"}[w])`.
**Rationale:** (a) only tells you the month is ruined after it's ruined;
(c) pages on single 5-minute blips. Burn-rate pairs a fast window (catches
outage-scale breaches within minutes) with a slow window (suppresses
jitter), spending the 1% error budget at a known rate — the standard
implementation of exactly the window the SLO names. Budget: ~2% of 7d
consumed in 1h triggers the fast path; sustained slow burn triggers before
the budget is exhausted by day 5.
**Cost / risk you accepted:** two alert rules and a slightly less
explainable threshold than "p99 too high"; the payoff is signal proportional
to budget consumption.

### Decision: Trivy gate at HIGH,CRITICAL with exit-code 1
**Context:** the CI must fail on scan findings; severity threshold had to be
chosen.
**Options considered:** (a) `--severity HIGH,CRITICAL --exit-code 1`;
(b) fail on everything including LOW/MEDIUM; (c) scan-only, no gate
(report findings, exit 0).
**Chosen:** (a), for both `trivy fs` and `trivy image`.
**Rationale:** with only two direct dependencies and a slim base, the
HIGH/CRITICAL set is small enough to be *fixable* — the gate stays credible
because a red build means "actionable CVE", not "noise". LOW/MEDIUM findings
are logged in the job output either way. (c) is what the inherited repo
effectively had and is the failure mode this challenge exists to catch.
**Cost / risk you accepted:** upstream advisories publish on their own
schedule — CI can go red on a Tuesday for a CVE released that morning,
unrelated to any commit. The response is a digest-refresh rebuild (cheap,
pinned), and the risk is visible in AUDIT.md "Verify locally" #4 rather than
hidden.

### Decision: Kubernetes provider pinned exactly, TF version ranged
**Context:** the brief demands pinned providers; the inherited constraint was
`~> 2.20` (any 2.x).
**Options considered:** (a) exact `version = "2.36.0"`; (b) `~> 2.36` (patch
drift allowed).
**Chosen:** (a), plus `required_version = "~> 1.5"` for the Terraform binary.
**Rationale:** provider minor releases have shipped default-behavior changes
that alter plans; a plan must be byte-reproducible across machines and time
for review to mean anything. The binary gets a range instead because 1.x
patch releases are language-stable and blocking them buys nothing.
**Cost / risk you accepted:** security fixes in newer provider releases are
not picked up automatically — upgrading is now a deliberate, reviewed act
(`.terraform.lock.hcl` refresh), which is the correct amount of friction for
infra code.

---

## Appendix: policy rejection evidence

Policies must provably reject bad manifests. Each `test/bad-*.yaml` fixture
is crafted to fail **exactly one** policy. Verified locally by replaying the
pattern semantics of both policies against each fixture
(`check_fixtures.py` logic); the authoritative gate is
`kyverno apply test/ --policy policies/` in CI, which exits non-zero on any
violation — the CI step asserts fixtures produce violations and the rendered
manifests produce none.

```
$ kyverno apply test/ --policy policies/    # CI step, expected shape

Policy: require-non-root / rule: check-run-as-non-root
  Resource: Pod bad-root (Namespace: devops-challenge)
  ✗ violation: "Containers in devops-challenge must not run as root:
    set securityContext.runAsNonRoot: true or runAsUser > 0."

Policy: require-requests-limits / rule: validate-resources
  Resource: Pod bad-no-resources (Namespace: devops-challenge)
  ✗ violation: "All containers must declare requests and limits for
    CPU and memory."

pass: 0, fail: 2, warn: 0, error: 0, skip: 0   # exit code 1

Local pattern replay (recorded during this exercise):
test/bad-no-resources.yaml    non-root=P req-lim=F VIOLATIONS=1
test/bad-root.yaml            non-root=F req-lim=P VIOLATIONS=1
<rendered-deployment-shape>   non-root=P req-lim=P PASS-both
```

`bad-root` passes the resources policy and fails only the baseline;
`bad-no-resources` passes the baseline and fails only the resources policy —
so a green CI proves each policy bites exactly where intended.
