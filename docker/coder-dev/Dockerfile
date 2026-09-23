# Prebaked dev environment for Coder workspaces (dev-k8s template default).
# Built multi-arch by .github/workflows/coder-dev-image.yaml and published to
# ghcr.io/lukasparke/coder-dev, so workspace pods skip the runtime
# apt-get bootstrap entirely.
FROM docker.io/library/ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      fd-find \
      git \
      jq \
      less \
      nano \
      openssh-client \
      procps \
      python3 \
      python3-pip \
      python3-venv \
      ripgrep \
      rsync \
      unzip \
      vim \
      zip \
    && rm -rf /var/lib/apt/lists/*
