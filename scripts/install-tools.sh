#!/usr/bin/env bash
# install-tools.sh — fetch, verify and install every pinned tool the runner image carries.
#
# RUN AT BUILD TIME ONLY, as root, from the Dockerfile, which COPYs it in and deletes it afterwards.
# It reads its pins from the environment; the Dockerfile's ARGs are the single source of truth for
# every version and digest, and this script refuses to run if any of them is missing.
#
# WHY A SCRIPT AND NOT A HEREDOC IN THE DOCKERFILE: `RUN <<'EOF'` is a BuildKit feature. Under the
# classic builder it degrades to `sh -c "<<'EOF'"` — a no-op that exits 0 — and the image builds
# "successfully" with none of these tools installed. A COPYed script executes identically under both
# builders, and has the side benefit of being lintable by the same shellcheck this image ships.
#
# This mirrors install_pinned_tarball() in homelab-infra/scripts/ci/tools.sh:185 — download, verify,
# install. A digest mismatch is fatal: there is deliberately no fallback to an unverified binary.
set -euo pipefail

# Fail loudly and by name if the Dockerfile stopped passing a pin, rather than installing "latest".
: "${SHELLCHECK_VERSION:?}" "${SHELLCHECK_SHA256:?}"
: "${KUSTOMIZE_VERSION:?}" "${KUSTOMIZE_SHA256:?}"
: "${KUBECONFORM_VERSION:?}" "${KUBECONFORM_SHA256:?}"
: "${KUBECTL_VERSION:?}" "${KUBECTL_SHA256:?}"
: "${HELM_VERSION:?}" "${HELM_SHA256:?}"
: "${NODE_VERSION:?}" "${NODE_SHA256:?}"
: "${RUNNER_TOOL_CACHE:?}"

readonly BIN_DIR=/usr/local/bin

work="$(mktemp -d)"
readonly work
trap 'rm -rf "$work"' EXIT

fetch_verified() { # <url> <sha256> <dest>
	local url="$1" want="$2" dest="$3"
	curl --fail --silent --show-error --location --retry 3 --output "$dest" -- "$url"
	printf '%s  %s\n' "$want" "$dest" | sha256sum --check --strict --quiet -
}

# --- shellcheck ---------------------------------------------------------------------------------
# NOTE the version. .pre-commit-config.yaml pins the hook at rev 0.10.0.1, but that is a PACKAGING
# revision of the shellcheck-py wrapper — upstream has no 0.10.0.1 and that URL 404s. v0.10.0 is the
# binary it wraps. This copy does NOT satisfy the pre-commit hook (which builds its own isolated
# env); it exists for test_harness.sh:1175 and test_router.sh:158, which lint with PATH's linter.
#
# (The line above is worded to avoid starting with a '#' immediately followed by the linter's own
# name: ShellCheck parses that as a directive and aborts the entire file with SC1073/SC1072, taking
# every other check in it down silently.)
fetch_verified \
	"https://github.com/koalaman/shellcheck/releases/download/${SHELLCHECK_VERSION}/shellcheck-${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
	"$SHELLCHECK_SHA256" "$work/shellcheck.tar.xz"
tar -xJf "$work/shellcheck.tar.xz" -C "$work" "shellcheck-${SHELLCHECK_VERSION}/shellcheck"
install -m 0755 "$work/shellcheck-${SHELLCHECK_VERSION}/shellcheck" "$BIN_DIR/shellcheck"

# --- kustomize ----------------------------------------------------------------------------------
# The release tag is `kustomize/vX.Y.Z` and the slash MUST arrive percent-encoded (%2F), or GitHub
# answers 404 — the same trap homelab-infra/scripts/ci/tools.sh:52 calls out.
fetch_verified \
	"https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" \
	"$KUSTOMIZE_SHA256" "$work/kustomize.tar.gz"
tar -xzf "$work/kustomize.tar.gz" -C "$work" kustomize
install -m 0755 "$work/kustomize" "$BIN_DIR/kustomize"

# --- kubeconform --------------------------------------------------------------------------------
fetch_verified \
	"https://github.com/yannh/kubeconform/releases/download/${KUBECONFORM_VERSION}/kubeconform-linux-amd64.tar.gz" \
	"$KUBECONFORM_SHA256" "$work/kubeconform.tar.gz"
tar -xzf "$work/kubeconform.tar.gz" -C "$work" kubeconform
install -m 0755 "$work/kubeconform" "$BIN_DIR/kubeconform"

# --- kubectl ------------------------------------------------------------------------------------
fetch_verified \
	"https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
	"$KUBECTL_SHA256" "$work/kubectl"
install -m 0755 "$work/kubectl" "$BIN_DIR/kubectl"

# --- helm ---------------------------------------------------------------------------------------
fetch_verified \
	"https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" \
	"$HELM_SHA256" "$work/helm.tar.gz"
tar -xzf "$work/helm.tar.gz" -C "$work" linux-amd64/helm
install -m 0755 "$work/linux-amd64/helm" "$BIN_DIR/helm"

# --- node, into the hosted tool cache -------------------------------------------------------------
# Not /usr/local, because the point is for actions/setup-node to FIND it. The `.complete` marker
# beside the version directory is what the actions toolkit treats as "this entry is usable" —
# without it setup-node ignores the directory and downloads anyway, and this whole step is
# decorative. The symlinks then put the same copy on PATH for anything that calls `node` directly
# without going through an action; symlinks rather than a PATH entry so the version lives in exactly
# one place (the ARG) and cannot drift.
fetch_verified \
	"https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
	"$NODE_SHA256" "$work/node.tar.xz"
node_dir="${RUNNER_TOOL_CACHE}/node/${NODE_VERSION}/x64"
mkdir -p "$node_dir"
tar -xJf "$work/node.tar.xz" -C "$node_dir" --strip-components=1
touch "${RUNNER_TOOL_CACHE}/node/${NODE_VERSION}/x64.complete"
for b in node npm npx; do
	ln -sf "$node_dir/bin/$b" "$BIN_DIR/$b"
done

# setup-node writes here when it DOES miss (a workflow asking for a version we did not bake), so the
# tree has to be writable by the unprivileged user the runner actually runs as.
chown -R runner:runner "$RUNNER_TOOL_CACHE"
