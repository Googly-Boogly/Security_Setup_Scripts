# Base image for sandboxed agents (built by: agent_runner.sh --build-image).
#
# Deliberately small: no sudo, no SSH, no Docker CLI. The runner adds the
# real controls at run time (read-only root, no capabilities,
# no-new-privileges, resource limits, network policy, non-root UID).
#
# For reproducible builds pin the base image by digest, e.g.
#   docker build --build-arg BASE_IMAGE=python:3.12-slim@sha256:<digest> ...
ARG BASE_IMAGE=docker.io/library/python:3.12-slim
FROM ${BASE_IMAGE}

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates git curl \
 && rm -rf /var/lib/apt/lists/*

# Fallback identity when the runner does not override the UID.
RUN useradd --create-home --uid 10001 --shell /bin/bash agent

# The root filesystem is read-only at run time: keep caches in /tmp and
# install project dependencies into a venv inside /workspace.
ENV HOME=/tmp \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /workspace
USER 10001:10001
CMD ["bash"]
