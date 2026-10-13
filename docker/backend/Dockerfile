# ---------- stage 1: builder ----------
FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
WORKDIR /build

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gcc g++ \
    && rm -rf /var/lib/apt/lists/*

COPY backend/pyproject.toml backend/
# The feature contract lives in the ml package at the repository root and is a build
# input, not a runtime one: backend/pyproject.toml packs `rul` into the backend wheel
# by pointing setuptools at `../ml/src`, so nothing under ml/ is COPYed into the
# runtime stage. `rul.contract` imports only the standard library.
#
# backend/ and ml/ must land as SIBLINGS under /build rather than being flattened
# into it: `../ml/src` resolves relative to backend/pyproject.toml. The old layout —
# backend's files copied straight into /build — is exactly why the contract could
# only be installed by running `pip install ./ml` before `pip install .`, and why
# `pip install ./backend` alone could not resolve `rul`.
#
# Only pyproject.toml and ml/ are COPYed, not all of backend/, so a change to
# application source still does not invalidate this dependency layer.
COPY ml/ ml/
RUN python -m venv /opt/venv \
 && /opt/venv/bin/pip install --upgrade pip \
 && /opt/venv/bin/pip install "./ml" \
 && /opt/venv/bin/pip install "./backend" \
 && /opt/venv/bin/pip uninstall -y nvidia-nccl-cu12 pip setuptools \
 && find /opt/venv -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true \
 && find /opt/venv -type f \( -name "*.pyc" -o -name "*.pyo" -o -name "*.a" -o -name "*.h" -o -name "*.hpp" \) -delete 2>/dev/null || true \
 && find /opt/venv -type d \( -name "tests" -o -name "test" -o -name "doc" -o -name "docs" -o -name "examples" \) -exec rm -rf {} + 2>/dev/null || true


# ---------- stage 2: runtime ----------
FROM python:3.11-slim AS runtime

LABEL org.opencontainers.image.title="Fleet Digital Twin API" \
      org.opencontainers.image.description="FastAPI + PostgreSQL + XGBoost predictive-maintenance backend" \
      org.opencontainers.image.source="https://github.com/OWNER/predictive-aircraft-maintenance"

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:$PATH" \
    FDT_DATA_DIR=/app/data

RUN groupadd -r fdt && useradd -r -g fdt -d /app fdt
WORKDIR /app

COPY --from=builder /opt/venv /opt/venv

COPY backend/alembic/ alembic/
COPY backend/alembic.ini backend/pyproject.toml ./
COPY backend/app/ app/
COPY backend/scripts/ scripts/
# The suite ships in the image (~100 KB) so that `make test`, `make lint` and
# `make typecheck` run with no local Python toolchain. Drop this line and this COPY if
# you build a stripped production image and run the suite from a separate stage.
COPY backend/tests/ tests/
# data/raw (fleet CSVs, ~600 KB) ships in the image; data/cmapss (43 MB of NASA
# telemetry) and data/ml (trained artifacts) are bind-mounted — see
# docker-compose.yml and scripts/fetch-cmapss.sh.
COPY backend/data/raw/ data/raw/

# The telemetry and the fleet CSVs are read at FDT_DATA_DIR on startup, and a wrong
# path there degrades silently: the replay engine comes up with no aircraft and the
# seed writes nothing. Fail the build instead of shipping that.
RUN python -c "import os,pathlib; d=pathlib.Path(os.environ['FDT_DATA_DIR']); \
    assert (d/'raw').is_dir(), f'{d}/raw missing'; \
    print('data dir OK:', d)"

RUN mkdir -p /app/data/cmapss /app/data/ml && chown -R fdt:fdt /app

USER fdt
EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=3s --start-period=40s --retries=3 \
  CMD python -c "import urllib.request,sys; \
      sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz',timeout=2).status==200 else 1)"

# --workers 1: the replay engine is an in-process task. Multiple workers would run
# multiple replay loops and double-advance every aircraft (docs/11 §2). Scale out with
# FDT_DEMO_MODE=false and an external ingest feed instead.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "1", "--proxy-headers"]