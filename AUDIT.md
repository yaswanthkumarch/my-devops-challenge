# AUDIT.md

Audit of the inherited starter repo, as first read on the day of handover.
Every quoted line existed verbatim in the original files. `Fix status`
reflects the state of this repository after hardening. Items whose defect
depends on runtime behavior rather than anything visible in the code are
listed under [Verify locally](#verify-locally) instead of asserted here.

Summary: **31 defects** — 9 Security, 13 Reliability, 6 Hygiene, 3
Documentation. 30 fixed, 1 accepted-with-rationale (see A-9).

---

## Security

### S-1 — Unpinned, non-minimal, EOL base image
- **File:** `Dockerfile`
- **Quote:** `FROM python:3.9`
- **What's wrong:** floating `3.9` tag (not a digest), full Debian image with
  build toolchain, and Python 3.9 reached end-of-life in October 2025.
- **Production impact:** builds are not reproducible and the image carries a
  large CVE surface that no longer receives security fixes.
- **Fix:** `python:3.12-slim-bookworm` pinned by digest, slim variant only.
- **Fix status:** FIXED

### S-2 — Container runs as root
- **File:** `Dockerfile`
- **Quote:** the file has no `USER` directive (ends `CMD ["python", "main.py"]`)
- **What's wrong:** no non-root user; the process runs as UID 0.
- **Production impact:** any container escape lands directly as root on the node.
- **Fix:** dedicated UID 10001 (`>= 10000` for the Kyverno baseline), `USER` as
  the last privilege-relevant directive.
- **Fix status:** FIXED

### S-3 — Flask dev server is the production entrypoint
- **File:** `Dockerfile` + `app/main.py`
- **Quote:** `CMD ["python", "main.py"]` and `app.run(host="0.0.0.0", port=80)`
- **What's wrong:** Werkzeug's development server (which itself prints
  "Do not use it in a production deployment") is PID 1.
- **Production impact:** no production request handling, no worker model, no
  graceful shutdown; a single request can wedge the whole service.
- **Fix:** gunicorn in exec form as PID 1, config with `graceful_timeout`.
- **Fix status:** FIXED

### S-4 — Plaintext secret committed to the chart values
- **File:** `helm/skybyte-app/values.yaml`
- **Quote:** `apiToken: "sk-skybyte-prod-7f3c9a2b1e8d4a6c"`
- **What's wrong:** a live-looking API token in version control; rotation
  cannot remove it from git history.
- **Production impact:** anyone with repo read access holds a prod credential
  forever, including after "rotation".
- **Fix:** removed from values; secret owned by Terraform `kubernetes_secret`
  with a sensitive variable and no default; Helm references it via
  `secretKeyRef`.
- **Fix status:** FIXED

### S-5 — Same secret duplicated as a Terraform variable default
- **File:** `terraform/variables.tf`
- **Quote:** `default     = "sk-skybyte-prod-7f3c9a2b1e8d4a6c"`
- **What's wrong:** the token exists in two files (values.yaml + variables.tf),
  is not marked `sensitive`, and would print in plan/apply output.
- **Production impact:** two sources of truth that can drift, and the value
  leaks into terminal logs, CI logs, and state.
- **Fix:** `sensitive = true`, default removed, value supplied via
  `TF_VAR_api_token` only.
- **Fix status:** FIXED

### S-6 — Secret injected as plain env value in the Deployment spec
- **File:** `helm/skybyte-app/templates/deployment.yaml`
- **Quote:** `value: {{ .Values.apiToken | quote }}`
- **What's wrong:** the token is rendered into the Deployment manifest, so it
  is visible to anyone with `get deployments` rights and in Helm release
  metadata.
- **Production impact:** broadens read access to the credential from
  `secrets` to `deployments`.
- **Fix:** `valueFrom.secretKeyRef` pointing at the Terraform-owned secret.
- **Fix status:** FIXED

### S-7 — No securityContext anywhere in the pod spec
- **File:** `helm/skybyte-app/templates/deployment.yaml`
- **Quote:** the `spec:` block contains no `securityContext` key
- **What's wrong:** no `runAsNonRoot`, no `readOnlyRootFilesystem`, no
  `allowPrivilegeEscalation: false`, no capability drop, no `seccompProfile`.
- **Production impact:** a compromised container gets root, a writable root
  filesystem, all default capabilities, and no seccomp filter.
- **Fix:** pod-level `runAsNonRoot/runAsUser/fsGroup/seccompProfile:
  RuntimeDefault`; container-level `readOnlyRootFilesystem: true`,
  `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, plus an
  `emptyDir` at `/tmp` so the read-only rootfs still works.
- **Fix status:** FIXED

### S-8 — No vulnerability scanning of source or image
- **File:** `.github/workflows/ci.yml`
- **Quote:** `run: docker build -t skybyte/app:ci .` (last step of the pipeline)
- **What's wrong:** the image is built and never scanned; neither is the
  source tree.
- **Production impact:** known-CVE dependencies ship because nothing fails.
- **Fix:** Trivy `fs` and `image` scans with `--exit-code 1 --severity
  HIGH,CRITICAL`.
- **Fix status:** FIXED

### S-9 — Privileged port 80 assumed throughout
- **File:** `Dockerfile`, `app/main.py`
- **Quote:** `EXPOSE 80` / `app.run(host="0.0.0.0", port=80)`
- **What's wrong:** binding <1024 requires root or `CAP_NET_BIND_SERVICE` —
  which directly conflicts with S-2 and with dropping ALL capabilities.
- **Production impact:** keeps the design locked to running as root.
- **Fix:** moved to 8080 end-to-end (Dockerfile `EXPOSE`, gunicorn `bind`,
  `containerPort`, probe ports); Service still exposes 80 externally via
  `targetPort: http`.
- **Fix status:** FIXED (surfaced as a conflict rather than silently chosen —
  the README's "listens on port 80" claim was part of the same mistake)

## Reliability

### R-1 — Liveness and readiness both probe the business endpoint
- **File:** `helm/skybyte-app/templates/deployment.yaml`
- **Quote:** `path: /` (appears twice, in `livenessProbe` and `readinessProbe`)
- **What's wrong:** both probes hit `/`, with identical default thresholds; a
  slow-but-alive app gets restarted, and readiness never distinguishes
  "wedged" from "not ready".
- **Production impact:** liveness on the business path converts a latency
  blip into a restart loop that takes every replica down at once.
- **Fix:** liveness on `/healthz`, readiness on `/readyz`, tuned thresholds
  (see DECISIONS.md "Probe numbers").
- **Fix status:** FIXED

### R-2 — `/healthz` is a stub; no readiness endpoint exists
- **File:** `app/main.py`
- **Quote:** `# TODO: actually check something useful` and `return "ok", 200`
- **What's wrong:** the health endpoint is a placeholder returning plain text;
  `/readyz` did not exist at all.
- **Production impact:** orchestrators gate traffic on a check that verifies
  nothing.
- **Fix:** real `/healthz` (dependency-free liveness) and `/readyz`
  (readiness) returning JSON.
- **Fix status:** FIXED

### R-3 — No resource requests or limits
- **File:** `helm/skybyte-app/values.yaml` + `templates/deployment.yaml`
- **Quote:** no `resources:` key anywhere in either file
- **What's wrong:** the pod is BestEffort — and because Terraform creates a
  ResourceQuota tracking `limits.memory` (R-4), pod creation is in fact
  **rejected by admission** rather than merely unbounded.
- **Production impact:** the chart as shipped cannot create a pod in the
  namespace Terraform provisions; where no quota exists, the pod would be
  first in line for eviction and free to starve neighbors.
- **Fix:** `requests: 50m/64Mi`, `limits: 100m/128Mi` (sizing rationale in
  values.yaml comments).
- **Fix status:** FIXED

### R-4 — ResourceQuota covers only memory limits
- **File:** `terraform/main.tf`
- **Quote:** `"limits.memory" = var.memory_quota`
- **What's wrong:** the quota constrains a single dimension; CPU and requests
  are unbounded at namespace level.
- **Production impact:** half a guardrail — and the one key it does track is
  exactly the key the chart omits, so the two halves of the repo contradict
  each other (see R-3).
- **Fix:** quota now covers `requests.cpu/memory` and `limits.cpu/memory`,
  matching what the chart declares.
- **Fix status:** FIXED

### R-5 — No graceful shutdown
- **File:** `app/main.py` + `Dockerfile`
- **Quote:** `app.run(host="0.0.0.0", port=80)` (no signal handling anywhere)
- **What's wrong:** on SIGTERM the dev server dies immediately, dropping
  in-flight requests.
- **Production impact:** every rollout drops live requests — user-visible 502s
  on each deploy.
- **Fix:** gunicorn `graceful_timeout: 20` inside
  `terminationGracePeriodSeconds: 30`: stop accepting, drain, exit.
- **Fix status:** FIXED

### R-6 — `terminationGracePeriodSeconds` unspecified in the chart
- **File:** `helm/skybyte-app/templates/deployment.yaml`
- **Quote:** no `terminationGracePeriodSeconds` key in the pod spec
- **What's wrong:** relies on the default; the drain budget is implicit and
  undocumented relative to app-level drain time.
- **Production impact:** if a future process needs longer to drain than the
  default allows, requests get cut with no signal as to why.
- **Fix:** explicit `30`, matched against gunicorn `graceful_timeout: 20`
  (10s of slack).
- **Fix status:** FIXED

### R-7 — Mutable `:latest` image tag
- **File:** `helm/skybyte-app/values.yaml`
- **Quote:** `tag: latest`
- **What's wrong:** combined with `pullPolicy: IfNotPresent`, a node that
  already has `skybyte/app:latest` never re-pulls.
- **Production impact:** "deploys" that silently run the previous image;
  rollbacks are impossible because the tag points at everything it ever was.
- **Fix:** pinned `tag: "1.0.0"` matching `Chart.yaml appVersion`; setup.sh
  passes the tag it actually built.
- **Fix status:** FIXED

### R-8 — setup.sh has no error handling
- **File:** `setup.sh`
- **Quote:** the script has no `set` line; starts with `echo "==> Building Docker image"`
- **What's wrong:** without `set -euo pipefail`, a failed `docker build` still
  proceeds to Terraform and Helm; `cd terraform` failure cascades; exit code
  is the last command's.
- **Production impact:** a half-deployed state reports success.
- **Fix:** `set -euo pipefail`, `--wait` on Helm so admission failures fail
  the script, explicit success line.
- **Fix status:** FIXED

### R-9 — setup.sh builds `:latest` and never loads it into the cluster
- **File:** `setup.sh`
- **Quote:** `docker build -t skybyte/app:latest .`
- **What's wrong:** builds a mutable tag and never loads it into kind/minikube,
  so with `IfNotPresent` the cluster may never see the new image at all.
- **Production impact:** "setup ran fine" while the cluster runs stale code.
- **Fix:** versioned tag via `IMAGE_TAG`, `kind load`/`minikube image load`
  detection.
- **Fix status:** FIXED

### R-10 — Helm upgrade has no wait
- **File:** `setup.sh`
- **Quote:** `helm upgrade --install skybyte-app helm/skybyte-app \` (no `--wait`)
- **What's wrong:** Helm exits 0 once objects are accepted by the API, not
  once pods are actually Ready.
- **Production impact:** admission-rejected pods (R-3) report as a successful
  deploy.
- **Fix:** `--wait --timeout 2m`.
- **Fix status:** FIXED

### R-11 — CI lint steps are hardcoded to succeed
- **File:** `.github/workflows/ci.yml`
- **Quote:** `run: flake8 app/ --exclude=app/* --exit-zero`,
  `run: helm lint helm/skybyte-app || true`,
  `terraform validate || true`
- **What's wrong:** three separate mechanisms force success: `--exit-zero`
  (flake8), `|| true` (helm, terraform) — and the flake8 `--exclude=app/*`
  glob excludes the very directory being linted, so nothing was checked at
  all.
- **Production impact:** green CI is meaningless; broken code ships.
- **Fix:** `ruff check app/` (fails on violation), bare `helm lint`, bare
  `terraform validate`, plus `terraform fmt -check`.
- **Fix status:** FIXED

### R-12 — CI never runs the tests
- **File:** `.github/workflows/ci.yml`
- **Quote:** no step invokes `pytest` (steps: flake8, helm, terraform, docker)
- **What's wrong:** the existing tests exist but never execute in CI.
- **Production impact:** regressions to `/` and `/healthz` ship unnoticed.
- **Fix:** pytest step including new metrics-contract tests (counter exists
  and increments via the test client).
- **Fix status:** FIXED

### R-13 — Rendered manifests never schema-validated; no policy gate
- **File:** `.github/workflows/ci.yml`
- **Quote:** `run: helm lint helm/skybyte-app || true` (the only chart check)
- **What's wrong:** `helm lint` does not catch schema-invalid manifests
  (wrong field types, unknown fields), and no admission-policy check runs.
- **Production impact:** malformed manifests reach the cluster and fail at
  apply-time — or worse, at runtime.
- **Fix:** `helm template` → `kubeconform -strict -summary` → `kyverno apply`
  of both policies, plus a negative test asserting the bad fixtures are
  rejected.
- **Fix status:** FIXED

## Hygiene

### H-1 — pip cache baked into image layer
- **File:** `Dockerfile`
- **Quote:** `RUN pip install -r requirements.txt`
- **What's wrong:** no `--no-cache-dir`; wheel cache stays in the layer.
- **Production impact:** larger image, slower pulls, bigger attack surface.
- **Fix:** `pip install --no-cache-dir`.
- **Fix status:** FIXED

### H-2 — Tests and caches shipped in the production image
- **File:** `Dockerfile`
- **Quote:** `COPY app/ /app/`
- **What's wrong:** copies everything under `app/`, including tests and
  `__pycache__`; no `.dockerignore` existed.
- **Production impact:** image bloat and unnecessary surface in production.
- **Fix:** `.dockerignore` excluding tests/caches/docs/scripts.
- **Fix status:** FIXED

### H-3 — Single stale dependency pin; no dev requirements file
- **File:** `app/requirements.txt`
- **Quote:** `flask==2.3.3`
- **What's wrong:** one pin from 2023; transitive Werkzeug unbounded; no
  gunicorn/prometheus_client (features missing entirely) and no test pins.
- **Production impact:** known CVEs in unbounded transitives ship to prod.
- **Fix:** pinned flask 3.1.0 / gunicorn 23.0.0 / prometheus-client 0.21.1;
  test/lint pins split into `requirements-dev.txt` so prod installs stay lean.
- **Fix status:** FIXED

### H-4 — CI lints a different Python than ships
- **File:** `.github/workflows/ci.yml`
- **Quote:** `python-version: '3.9'`
- **What's wrong:** CI ran 3.9 while the (new) image ships 3.12.
- **Production impact:** syntax/deprecation differences validated in CI don't
  match runtime.
- **Fix:** CI Python 3.12, matching the base image.
- **Fix status:** FIXED

### H-5 — Floating provider version constraint
- **File:** `terraform/versions.tf`
- **Quote:** `version = "~> 2.20"`
- **What's wrong:** any kubernetes provider release from 2.20 to <3.0 is
  acceptable; plans are not reproducible across machines.
- **Production impact:** a provider release can change plan output between
  two runs of the same code.
- **Fix:** exact pin `2.36.0`; `required_version` tightened to `~> 1.5`.
- **Fix status:** FIXED

### H-6 — Values keys referenced by templates but absent from values.yaml
- **File:** `helm/skybyte-app/values.yaml` + `templates/_helpers.tpl`
- **Quote:** `{{- if .Values.fullnameOverride }}` and
  `{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}`
  — with no `nameOverride`/`fullnameOverride` keys in values.yaml
- **What's wrong:** benign today (Helm nil-defaulting) but the contract is
  implicit; a template refactor could turn nil into a render error.
- **Production impact:** minor — surprise render failures during edits.
- **Fix:** both keys declared in values.yaml with empty-string defaults.
- **Fix status:** FIXED

## Documentation

### D-1 — README claims a non-root `appuser` that never existed
- **File:** `README.md`
- **Quote:** `[Client] ──► [Service:80] ──► [Pod:appuser:80]` and
  `The pod runs as a non-root user (appuser) and listens on port 80.`
- **What's wrong:** false on both counts — the image had no `USER` (root), and
  nothing named `appuser` existed in the repo.
- **Production impact:** onboarding engineers trust a security property that
  was never true.
- **Fix:** architecture section corrected; security properties now verifiable
  via `system-checks.sh` rather than asserted in prose.
- **Fix status:** FIXED

### D-2 — Prerequisites without versions; no SLO; no "what was wrong"
- **File:** `README.md`
- **Quote:** `- Docker Desktop (or any Docker engine)` (and the rest of the
  prerequisites list — no versions anywhere)
- **What's wrong:** untestable prerequisites, no SLO statement, no record of
  the inherited defects.
- **Production impact:** nobody can reproduce the environment or know the
  service's reliability contract.
- **Fix:** prerequisites with concrete versions, SLO statement with alerting
  approach, "what was wrong" paragraph, "next with another week" section.
- **Fix status:** FIXED

### D-3 — Secret-rotation comment contradicts the design
- **File:** `helm/skybyte-app/values.yaml`
- **Quote:** `# API token used by the service. Rotate quarterly.`
- **What's wrong:** the comment prescribes quarterly rotation while the
  design (plaintext in git) means every rotated value remains in history
  forever — rotation is theater under this scheme.
- **Production impact:** false confidence in the credential lifecycle.
- **Fix:** comment removed with the plaintext value; secret now lives outside
  git so rotation is real.
- **Fix status:** FIXED

## Verify locally

Runtime-dependent suspicions — not asserted above because nothing in the
pasted files proves them:

1. **Quota rejection of the original chart (R-3/R-4 interplay):** static
   reading says a namespace whose ResourceQuota tracks `limits.memory` rejects
   pods without memory limits. Confirm by applying the original chart into the
   TF-provisioned namespace and reading the Deployment's
   `FailedCreate`/quota-exceeded event.
2. **Dev-server SIGTERM behavior:** the Flask dev server is expected to drop
   in-flight requests on SIGTERM rather than drain. Confirm with a slow
   request + `kubectl delete pod` on the original image.
3. **Prometheus-side consumption of scrape annotations:** the annotations are
   the kube-prometheus-stack conventions, but whether *your* Prometheus
   actually scrapes Service annotations depends on the scrape config of the
   installed stack. Verify a target appears after install; if the stack only
   scrapes pods, move the annotations to the pod template (one-line change).
4. **Trivy results drift daily:** the pinned base image and deps pass
   HIGH/CRITICAL at fix time, but new advisories can fail CI on any given day.
   The accepted response is rebuilding with the refreshed digest — budgeted
   under "Things I would do next".
5. **kind/minikube image-load path in setup.sh:** the detection logic is
   standard but unexercised in this environment; run once against a fresh
   kind cluster to confirm.
6. **Actions pinned by major tag only** (`@v4`, `@v5`, `@v3`): tag pinning is
   mutable upstream. Listed here rather than in the diff because SHA-pinning
   was deliberately deferred (see README "next week" list).
