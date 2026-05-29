# Development image for gimie-api running against a live-mounted local gimie.
#
# gimie-api imports gimie as a Python package (`from gimie.project import Project`).
# Local gimie requires Python >=3.12, so we cannot reuse the stock python:3.9 image.
# We pre-install gimie==0.7.2 from PyPI to warm its (heavy) dependency tree, then the
# compose `command` overlays the mounted local source with an editable, --no-deps install.

FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

# System libraries gimie needs at runtime: git (repo introspection),
# libmagic-dev (file type detection), libgomp1 (OpenMP for numpy/scipy);
# gcc is kept for any source builds during editable installs.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        gcc \
        libgomp1 \
        libmagic-dev \
    && rm -rf /var/lib/apt/lists/*

# API runtime deps + gimie's full dependency tree (matched to the local 0.7.2 source).
# hatchling is needed so the runtime `pip install -e /gimie` (editable) build succeeds offline-ish.
RUN pip install \
        fastapi \
        uvicorn \
        pyyaml \
        hatchling \
        gimie==0.7.2

WORKDIR /
