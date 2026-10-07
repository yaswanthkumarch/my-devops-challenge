#!/usr/bin/env bash
# system-checks.sh — verify the hardening claims against the live cluster.
# Run after setup.sh. Any failed assertion exits non-zero.
set -euo pipefail

NAMESPACE="devops-challenge"
LABEL="app.kubernetes.io/name=skybyte-app"
DEPLOY="skybyte-app"
FAILURES=0

check() { # check <desc> <cmd...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS: ${desc}"
  else
    echo "FAIL: ${desc}"
    FAILURES=$((FAILURES + 1))
  fi
}

POD="$(kubectl get pods -n "${NAMESPACE}" -l "${LABEL}" \
  -o jsonpath='{.items[0].metadata.name}')"
echo "==> Target pod: ${POD}"

echo "==> 1) In-container UID (must be non-zero)"
APP_UID="$(kubectl exec -n "${NAMESPACE}" "${POD}" -- id -u)"
echo "    UID=${APP_UID}"
check "UID is non-zero (non-root)" test "${APP_UID}" != "0"

echo "==> 2) Listening port and CapEff of PID 1"
echo "    PID 1 cmdline: $(kubectl exec -n "${NAMESPACE}" "${POD}" -- sh -c 'tr "\0" " " </proc/1/cmdline; echo')"
# /proc/net/tcp listens in hex: 1F90 = 8080 (our non-root-bindable port).
LISTEN_HEX="$(kubectl exec -n "${NAMESPACE}" "${POD}" -- sh -c \
  "awk 'NR>1 && \$4==\"0A\" {print \$2}' /proc/net/tcp | cut -d: -f2 | sort -u")"
echo "    Listening ports (hex): ${LISTEN_HEX}"
check "gunicorn listens on 8080 (hex 1F90)" grep -qx "1F90" <<< "${LISTEN_HEX}"
CAPEFF="$(kubectl exec -n "${NAMESPACE}" "${POD}" -- sh -c 'grep CapEff /proc/1/status' | awk "{print \$2}")"
echo "    CapEff=${CAPEFF}"
check "PID 1 has zero effective capabilities" test "${CAPEFF}" = "0000000000000000"

echo "==> 3) GET / returns the exact JSON body"
kubectl port-forward -n "${NAMESPACE}" "svc/${DEPLOY}" 18080:80 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill ${PF_PID} 2>/dev/null || true' EXIT
BODY=""
for _ in 1 2 3 4 5; do
  sleep 1
  BODY="$(curl -sf http://127.0.0.1:18080/ 2>/dev/null || true)"
  [ -n "${BODY}" ] && break
done
echo "    Body: ${BODY}"
# Flask jsonify sorts keys; this exact string is stable for this payload.
check "GET / body matches exactly" \
  test "${BODY}" = '{"message":"Hello, Candidate","version":"1.0.0"}'

echo "==> 4) GET /metrics exposes http_requests_total"
curl -sf http://127.0.0.1:18080/ >/dev/null 2>&1 || true  # generate traffic
METRICS="$(curl -sf http://127.0.0.1:18080/metrics 2>/dev/null || true)"
check "/metrics contains http_requests_total" grep -q "^http_requests_total{" <<< "${METRICS}"

echo "==> 5) Pod deletion recovers in <30s with no failed probes"
UNHEALTHY_BEFORE="$(kubectl get events -n "${NAMESPACE}" \
  --field-selector reason=Unhealthy --no-headers 2>/dev/null | wc -l | tr -d ' ')"
kubectl delete pod "${POD}" -n "${NAMESPACE}" --wait=false
if kubectl rollout status "deployment/${DEPLOY}" -n "${NAMESPACE}" --timeout=30s; then
  echo "PASS: new pod Ready within 30s"
else
  echo "FAIL: rollout did not recover within 30s"
  FAILURES=$((FAILURES + 1))
fi
sleep 5  # give a late probe failure time to surface as an event
UNHEALTHY_AFTER="$(kubectl get events -n "${NAMESPACE}" \
  --field-selector reason=Unhealthy --no-headers 2>/dev/null | wc -l | tr -d ' ')"
echo "    Unhealthy events before=${UNHEALTHY_BEFORE} after=${UNHEALTHY_AFTER}"
check "no new failed-probe events during rollout" \
  test "${UNHEALTHY_AFTER}" -le "${UNHEALTHY_BEFORE}"

echo "=================================="
if [ "${FAILURES}" -eq 0 ]; then
  echo "ALL SYSTEM CHECKS PASSED"
else
  echo "${FAILURES} SYSTEM CHECK(S) FAILED"
  exit 1
fi
