# github-runners

The custom [Actions Runner Controller](https://github.com/actions/actions-runner-controller) image
that runs CI for `homelab-infra` and `homelab-app-of-apps` on the `homelab-k8s-corporate` cluster.

Published to `ghcr.io/luishmg/github-runners`, built from
`ghcr.io/actions/actions-runner:2.336.0`.

## Why this image exists

Not for convenience — to stop a test suite from silently eroding.

`homelab-infra/scripts/tests/test_harness.sh` guards `make`, `shellcheck` and `kubectl` with
`command -v` and downgrades each to `_skip`. `_skip` increments **nothing** — not `FAIL`, not even a
skip counter — and the suite's exit code depends only on `FAIL`. So on a stock runner the suite
reports green while quietly running hundreds fewer assertions.

Measured, same commit, same suite:

| Image | Result | Skips |
|---|---|---|
| `ghcr.io/actions/actions-runner:2.336.0` | `PASS 1638 / FAIL 0`, **exit 0** | 12 |
| this image | `PASS 1902 / FAIL 0`, exit 0 | 0 |

**264 assertions — 14% of the suite — vanish without a single red signal.** That is the failure this
image removes, and it is why the acceptance criterion here is a *number* and never an exit code.

## What it carries

Everything is pinned and **sha256-verified at build time**; a digest mismatch fails the build, with
no fallback to an unverified binary. The versions are not chosen here — they are lifted from the pins
already in the consuming repos, so this image cannot drift from what CI would install itself.

| Tool | Version | Pin comes from |
|---|---|---|
| `make` | distro | *(unpinned anywhere; ~9 `test_harness.sh` skip sites + the `make-parse` hook)* |
| `shellcheck` | `v0.10.0` | `.pre-commit-config.yaml` hook rev `0.10.0.1` |
| `kustomize` | `v5.4.3` | `homelab-infra/scripts/ci/tools.sh` |
| `kubeconform` | `v0.6.7` | `homelab-infra/scripts/ci/tools.sh` |
| `pre-commit` | `4.6.0` | `homelab-infra/scripts/ci/tools.sh` |
| `kubectl` | `v1.36.2` | cluster `kubernetesVersion` |
| `helm` | `v3.16.3` | `homelab-infra/.github/workflows/drift.yml` |
| `node` | `22.23.0` | seeded into the hosted tool cache |
| `zstd`, `xz-utils`, `python3-venv` | distro | `actions/cache`; `.tar.xz` artefacts; `ensurepip` |

Two notes worth carrying:

- **`shellcheck` is `v0.10.0`, not `0.10.0.1`.** The latter is a `shellcheck-py` *packaging*
  revision; upstream has no such release and that URL 404s. This PATH copy does **not** satisfy the
  pre-commit hook, which builds its own isolated environment — it exists for `test_harness.sh` and
  `test_router.sh`, which lint with whatever `shellcheck` is on `PATH`.
- **Node is installed into `RUNNER_TOOL_CACHE` (`/opt/hostedtoolcache`), with the `.complete`
  marker.** Without that marker `actions/setup-node` ignores the directory and downloads anyway,
  making the layer decorative. `RUNNER_TOOL_CACHE` is unset in the base image and is set explicitly
  here so the location stays outside any volume ARC mounts over.

### Deliberately absent: `bao` and `pulumi`

The harness *stubs* both onto a temporary `PATH`; neither ever triggers a `_skip`, and no CI job
invokes them (`make -n` runs `.DEFAULT_GOAL := help`, not `check-tools`). The 1902 baseline was
measured on `ubuntu-latest`, where **both are absent** — adding them would cost ~400 MB and move this
image *away* from the environment the number was measured in. They belong here when Phase 7
`pulumi preview` lands, and not before.

## Verifying a change

```bash
docker build -t github-runners:local .
./scripts/verify-harness.sh github-runners:local ~/Projects/homelab-infra
```

`verify-harness.sh` asserts the exact count. **A lower `PASS` is a failure**, and the script prints
the suite's `SKIP` lines when the count is short — each one names the tool the image still lacks.
Never make it green by dropping a tool or relaxing an assertion.

There is a second, independent guard: the **final `RUN` in the `Dockerfile`** asserts every tool is
present *at its pinned version* before the image is finished. It is a plain `&&` chain rather than a
heredoc on purpose — see below.

> **Build with BuildKit or the classic builder; both work, by design.** `RUN <<'EOF'` heredocs are a
> BuildKit feature, and under the classic builder they degrade to `sh -c "<<'EOF'"` — a no-op that
> exits 0. An earlier revision of this Dockerfile did exactly that and produced an image missing five
> of its tools while reporting success. The install now lives in a COPYed script
> (`scripts/install-tools.sh`), which behaves identically under both builders and is lintable by the
> very `shellcheck` this image ships.

## CI

`.github/workflows/build.yml` builds on every pull request, and builds **and publishes** on pushes to
`main`. The assertions and the harness gate run *before* the push, so a broken image never reaches
GHCR and therefore never reaches the cluster.

**This repo is public, so its own CI runs on `ubuntu-latest` — hard-coded, never
`vars.RUNNER_LABEL`.** Attaching a self-hosted runner to a public repo lets anyone execute arbitrary
code on the homelab LAN via a fork pull request. The runners also cannot build the image they
themselves run on.

The harness gate needs read access to the private `homelab-infra`, via a
`HOMELAB_INFRA_READ_TOKEN` repository secret — a fine-grained PAT scoped to that one repo with
`Contents: Read-only`, and nothing else.

**A missing, revoked or expired token fails the build.** It is deliberately not tolerated, because a
gate that downgrades itself to a warning when its credential rots is the same silent-erosion shape
this image exists to eliminate — and fine-grained PATs expire within a year, so it *will* rot.

The single exception is a **pull request from a fork**: GitHub withholds secrets from those by design,
so no credential can reach the job and the gate genuinely cannot run. That case emits a notice, and
the Dockerfile build guard plus the toolchain assertions still apply. Before pinning an image built
only from a fork PR, either run `verify-harness.sh` locally or push the same commit to a branch in
this repo.

## Consuming it

`homelab-app-of-apps/homelab-k8s-corporate/arc/runners.yaml` pins this image **by digest**, once per
scale set, and `scripts/hooks/kustomize-validate.sh` asserts it appears exactly twice:

```yaml
# renovate: datasource=docker depName=ghcr.io/luishmg/github-runners
image: ghcr.io/luishmg/github-runners:2.336.0@sha256:…
```

**The digest is deliberately not written down here.** The build provenance attestation embeds the
commit SHA, so every publish produces a new index digest even when the image content is byte-for-byte
identical — a digest pasted into this README is stale the next time anything merges. The authoritative
value is printed in the build's job summary, ready to paste; `arc/runners.yaml` is the one place it
belongs.

Each push to `main` tags `:2.336.0`, `:sha-<full-commit-sha>` and `:latest`, and attaches an SBOM and
a Sigstore-signed build provenance attestation.

**No `imagePullSecret` is needed.** The GHCR package inherited this repo's public visibility on first
publish — verified by an unauthenticated manifest fetch against `ghcr.io/v2/`, which returns `200`.
That is worth knowing because the opposite is widely assumed; packages default to private only when
the owning repo is private. If the package is ever flipped to private, ARC will need a pull secret
and the runner pods will sit in `ImagePullBackOff` until it has one.
