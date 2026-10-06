# Pinned by digest (multi-arch index; digest fetched from Docker Hub at fix time).
# slim over distroless: pip installs natively in one stage AND a shell exists for
# the system-checks.sh exec probes (`id -u`, /proc reads). Distroless has no shell.
# 3.9 is EOL (Oct 2025) -> 3.12.
FROM python:3.12-slim-bookworm@sha256:34386ef0cb081344d7ec1c103ba398e6e9f64e9ab3a1509accc92a4e24a07258

# UID >= 10000 to satisfy the non-root baseline policy (kyverno-baseline.yaml).
# nologin shell: the account exists to own the process, not for logins.
RUN groupadd --gid 10001 app && \
    useradd --uid 10001 --gid app --shell /usr/sbin/nologin --create-home app

WORKDIR /app

# Bytecode: don't write .pyc (image is read-only under readOnlyRootFilesystem).
# Unbuffered: logs ship immediately to stdout for kubectl logs / collection.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Dependencies first so code-only changes don't invalidate this layer.
COPY app/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ /app/

# Last privilege-relevant directive; gunicorn (exec form, PID 1) runs as this user.
USER 10001

# 8080, not 80: non-root cannot bind <1024 and we drop ALL capabilities.
EXPOSE 8080

# exec-form gunicorn is PID 1: SIGTERM reaches it directly, it stops accepting
# connections, drains workers up to graceful_timeout=20s, exits inside the 30s
# terminationGracePeriodSeconds. Never run the Flask dev server here.
CMD ["gunicorn", "--config", "/app/gunicorn.conf.py", "main:app"]
