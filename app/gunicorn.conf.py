# Gunicorn config — every value below has a why in DECISIONS.md.
bind = "0.0.0.0:8080"  # non-root-bindable port, matches EXPOSE + containerPort

# Hello-world sizing: 1 worker covers the ResourceQuota CPU budget; 2 threads
# keep slow clients from blocking readiness probes.
workers = 1
threads = 2

# Hard kill for a wedged worker (a hung worker must not outlive its window).
timeout = 20

# SIGTERM drain window for in-flight requests. 20s of the 30s
# terminationGracePeriodSeconds: 10s left over for kubelet bookkeeping.
graceful_timeout = 20

keepalive = 5  # match typical LB idle timeouts; avoids premature 502s

# Logs to stdout/stderr — 12-factor; the kubelet owns log files.
accesslog = "-"
errorlog = "-"
