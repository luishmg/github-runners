# syntax=docker/dockerfile:1.7
# The ARC runner image for homelab-infra and homelab-app-of-apps.
#
# WHY THIS IMAGE EXISTS — it is not a convenience, it is a correctness fix. homelab-infra's
# scripts/tests/test_harness.sh guards `make`, `shellcheck` and `kubectl` with `command -v` and
# downgrades each to `_skip`, and `_skip` increments NOTHING. On a stock actions-runner the suite
# still exits 0, at a far lower PASS count than the 1897 it reaches on ubuntu-latest — a green that
# means much less, invisibly. Baking the tools in is what makes the count honest. The acceptance
# criterion for any change to this file is therefore a NUMBER, not an exit code:
#
#     scripts/verify-harness.sh <image> <homelab-infra checkout>   # PASS 1897 / FAIL 0
#
# A lower PASS is a FAILURE. Do not "fix" a red build by dropping a tool.
#
# WHAT IS DELIBERATELY ABSENT: `bao` and `pulumi`. The harness stubs both onto a temp PATH and
# neither ever triggers a `_skip`; no CI job invokes them (`make -n` runs .DEFAULT_GOAL := help, not
# check-tools). The 1897 baseline was measured on ubuntu-latest where BOTH are absent, so adding them
# would cost ~400 MB and move this image AWAY from the environment the number was measured in. They
# belong here when Phase 7 `pulumi preview` lands, and not before.
#
# EVERY DOWNLOAD IS PINNED AND sha256-VERIFIED, and the digests are not invented here: they are the
# ones already recorded in the two repos, so this image cannot drift from what CI installs itself.
# See the provenance comment on each ARG. A digest mismatch FAILS THE BUILD — there is no fallback to
# an unverified binary, by design.
#
# linux/amd64 ONLY. homelab-infra/scripts/ci/tools.sh:69-72 refuses any other platform out loud, and
# both runner paths (Proxmox VMs, GitHub-hosted ubuntu) are x86_64. A multi-arch build here would
# produce an arm64 image that CI would reject on first use.

FROM ghcr.io/actions/actions-runner:2.336.0@sha256:0cfdcc701ce933c6d243c6b0b2da767366dc9f2e99961d4c3754b0b78084cdda

# The base image runs as uid 1001 `runner`. Root is needed to install; the final USER puts it back.
# NOTE for anyone reading an older comment in either repo that says otherwise: `sudo` DOES work in
# this image (NOPASSWD, `runner` is in group 27) and apt-get functions. That claim was measured, and
# the comments asserting the opposite were wrong.
USER root

# --- the pins --------------------------------------------------------------------------------
#
# shellcheck: NOTE the version. `.pre-commit-config.yaml` pins the hook at rev 0.10.0.1, but that is
# a shellcheck-py PACKAGING revision — upstream shellcheck has no 0.10.0.1 and the URL 404s. v0.10.0
# is the binary that revision wraps. This PATH copy does NOT satisfy the pre-commit hook (which
# builds its own isolated env); it exists solely for test_harness.sh:1175 and test_router.sh:158,
# which lint with whatever `shellcheck` is on PATH.
ARG SHELLCHECK_VERSION=v0.10.0
ARG SHELLCHECK_SHA256=6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87

# kustomize + kubeconform: versions AND digests lifted verbatim from
# homelab-infra/scripts/ci/tools.sh:46-55, so `tools.sh` finds what it expects and becomes a no-op.
# The kustomize release tag is `kustomize/vX.Y.Z` and the slash MUST arrive percent-encoded (%2F) or
# GitHub answers 404.
ARG KUSTOMIZE_VERSION=v5.4.3
ARG KUSTOMIZE_SHA256=3669470b454d865c8184d6bce78df05e977c9aea31c30df3c669317d43bcc7a7
ARG KUBECONFORM_VERSION=v0.6.7
ARG KUBECONFORM_SHA256=95f14e87aa28c09d5941f11bd024c1d02fdc0303ccaa23f61cef67bc92619d73

# kubectl: matches the cluster exactly — k8s/homelab-k8s-corporate/Pulumi.corporate.yaml:128 pins
# kubernetesVersion v1.36.2. Bump this WITH the cluster, not ahead of it.
ARG KUBECTL_VERSION=v1.36.2
ARG KUBECTL_SHA256=1e9045ec32bea85da43de85f0065358529ea7c7a152eca78154fba5b58c27d82

# helm: the version homelab-infra/.github/workflows/drift.yml:54 pins, because it reproduces the
# committed cilium.yaml byte-for-byte. A different helm renders a different manifest and the drift
# gate goes red for a reason that has nothing to do with drift.
ARG HELM_VERSION=v3.16.3
ARG HELM_SHA256=f5355c79190951eed23c5432a3b920e071f4c00a64f75e077de0dd4cb7b294ea

# pre-commit: 4.6.0, matching homelab-infra/scripts/ci/tools.sh:44. app-of-apps' tools.sh probes for
# the EXACT string "pre-commit 4.6.0"; a newer patch release here would make it reinstall over this
# copy on every job, which is the whole thing this image exists to avoid.
ARG PRE_COMMIT_VERSION=4.6.0

# Node: the version the workstation runs. actions/setup-node resolves `node-version: '22'` against
# the tool cache first, so seeding it there turns that step into a cache hit instead of a ~30 MB
# download on every ephemeral pod. NO `v` PREFIX — the tool cache directory is named by bare
# semver, and this value is also used to build that path.
ARG NODE_VERSION=22.23.0
ARG NODE_SHA256=14d7de44f235534799f8b171a4050d9a6a4bc99c87e053a25d3d54afa580aa20

# RUNNER_TOOL_CACHE is UNSET in the base image, so actions/* fall back to $RUNNER_WORKSPACE/_tool —
# which ARC may mount an emptyDir over, discarding anything baked in. Setting it to /opt makes the
# location deterministic and outside every volume mount. AGENT_TOOLSDIRECTORY is the older spelling;
# some actions still read it, and disagreeing values are worse than either one alone. Declared here
# rather than after the install because the install RUN below reads it.
ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache \
    AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache

# --- packages --------------------------------------------------------------------------------
#
# make    — the big one: ~9 skip sites in test_harness.sh plus the `make-parse` pre-commit hook.
# xz-utils — the base image has tar but NOT xz; shellcheck and node both ship .tar.xz.
# zstd    — actions/cache detects zstd and silently falls back to gzip without it.
# python3-venv — provides ensurepip. python3 3.12.3 IS already in the base image; pip is what is
#           missing, and a venv is how we get a deterministic pre-commit without fighting PEP 668.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      make \
      xz-utils \
      zstd \
      python3-venv \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# --- pinned, sha256-verified binaries ----------------------------------------------------------
#
# The work is in a COPYed script rather than inline, for one specific reason: `RUN <<'EOF'` is a
# BuildKit feature, and under the CLASSIC builder it degrades to `sh -c "<<'EOF'"` — a no-op that
# exits 0, producing an image that is missing every one of these tools and reports success. A COPYed
# script executes identically under both builders. It is also lintable by the same shellcheck this
# image ships, which an inline blob is not.
#
# The ARGs above are the single source of truth for every version and digest; Docker exposes them to
# RUN as environment variables, and the script refuses to run if any is missing rather than
# defaulting to "latest".
COPY scripts/install-tools.sh /tmp/install-tools.sh
RUN /tmp/install-tools.sh && rm -f /tmp/install-tools.sh

# --- pre-commit ------------------------------------------------------------------------------
#
# A plain venv, not pipx. pipx IS a venv manager, and one venv with a symlink is fewer moving parts,
# needs nothing from universe, and sidesteps Ubuntu 24.04's PEP 668 externally-managed-environment
# refusal entirely. pre-commit still builds its own per-hook environments under ~/.cache/pre-commit
# at runtime exactly as it does everywhere else — this only fixes WHICH pre-commit runs.
RUN python3 -m venv /opt/pre-commit \
 && /opt/pre-commit/bin/pip install --no-cache-dir --quiet "pre-commit==${PRE_COMMIT_VERSION}" \
 && ln -s /opt/pre-commit/bin/pre-commit /usr/local/bin/pre-commit

# --- the build-time guard ----------------------------------------------------------------------
#
# ASSERT WHAT THE LAYERS ABOVE CLAIMED TO DO. This is not belt-and-braces; it is load-bearing, and
# it was added because the failure it catches actually happened: built with the CLASSIC (non-BuildKit)
# builder, `RUN <<'INSTALL'` is not a heredoc at all — it degrades to `sh -c "<<'INSTALL'"`, a no-op
# that exits 0. The image then builds "successfully" with five of its seven tools missing, and the
# only symptom downstream is test_harness.sh quietly reporting a lower PASS count. That is precisely
# the silent-erosion class this image exists to remove, so it must not be reachable from here.
#
# Deliberately a plain `&&` chain and NOT a heredoc: a heredoc guard would be no-op'd by the very
# builder it is meant to catch. Keep it that way.
#
# The version strings are asserted, not merely the presence of the binaries, because
# scripts/ci/tools.sh in both repos probes for EXACT output — `kustomize version` must print exactly
# v5.4.3 and `pre-commit --version` exactly "pre-commit 4.6.0", or it reinstalls over these copies on
# every job and the image achieves nothing.
RUN set -eu \
 && command -v make >/dev/null \
 && command -v zstd >/dev/null \
 && shellcheck --version | grep -qxF "version: ${SHELLCHECK_VERSION#v}" \
 && [ "$(kustomize version)" = "${KUSTOMIZE_VERSION}" ] \
 && [ "$(kubeconform -v)" = "${KUBECONFORM_VERSION}" ] \
 && [ "$(pre-commit --version)" = "pre-commit ${PRE_COMMIT_VERSION}" ] \
 && kubectl version --client 2>/dev/null | grep -qF "${KUBECTL_VERSION}" \
 && helm version --short | grep -qF "${HELM_VERSION}" \
 && [ "$(node --version)" = "v${NODE_VERSION}" ] \
 && [ -f "${RUNNER_TOOL_CACHE}/node/${NODE_VERSION}/x64.complete" ] \
 && echo "build guard: every pinned tool present at its pinned version"

# Back to the unprivileged user the runner is designed to run as. No ENTRYPOINT and no CMD: the
# scale set supplies `command: ["/home/runner/run.sh"]` (arc/runners.yaml), and overriding it here
# would silently win over the manifest.
USER runner
WORKDIR /home/runner
