#!/usr/bin/env bash
# verify-harness.sh — the acceptance criterion for the runner image, made repeatable.
#
# THE POINT OF THIS SCRIPT IS THE NUMBER, NOT THE EXIT CODE. homelab-infra's test_harness.sh guards
# `make`, `shellcheck` and `kubectl` with `command -v` and downgrades each to `_skip`, and `_skip`
# increments nothing — not FAIL, not even a SKIP counter. So a runner image missing a tool prints
# `FAIL 0`, exits 0, and looks perfectly green while having run hundreds fewer assertions. Checking
# `$?` here would therefore certify exactly the failure this image exists to prevent. We assert the
# exact PASS count instead, and a LOWER count is a failure.
#
# The suite is fully offline — bao, pulumi, curl and npm are all faked onto a temp PATH and HOME is a
# hermetic mktemp -d — so this needs no cluster, no OpenBao and no credentials.
#
# Usage: scripts/verify-harness.sh <image-ref> <path-to-homelab-infra-checkout>
set -euo pipefail

# --- the baselines ---------------------------------------------------------------------------
# Measured on ubuntu-latest and recorded in homelab-infra/.github/workflows/ci.yml:173-175, which
# also says: "Do not make it green by skipping a suite or relaxing an assertion." That applies here
# too — if this number moves, find out why before editing it.
readonly EXPECTED_HARNESS_PASS=1897
readonly EXPECTED_HARNESS_FAIL=0
readonly EXPECTED_ROUTER_FAIL=0

usage() {
	cat >&2 <<-EOF
		usage: $0 <image-ref> <path-to-homelab-infra-checkout>

		  e.g. $0 github-runners:local ~/Projects/homelab-infra
	EOF
	exit 2
}

[[ $# -eq 2 ]] || usage
readonly image="$1"
readonly repo="$2"

[[ -f "$repo/scripts/tests/test_harness.sh" ]] || {
	echo "not a homelab-infra checkout (no scripts/tests/test_harness.sh): $repo" >&2
	exit 2
}

# --- run one suite in the image --------------------------------------------------------------
# READ-ONLY mount, deliberately: the suite writes only into its hermetic HOME and into TMPDIR, so a
# read-write mount would buy nothing and put the caller's working tree — quite possibly with
# uncommitted work in it — at the mercy of a test.
#
# THE UID IS THE CALLER'S, NOT THE IMAGE'S `runner` (1001). The workstation umask is 027, so a
# checkout lands as 0750 owned by the caller, and uid 1001 cannot even read it — every suite dies
# with "Permission denied" before printing a summary line. That is a bind-mount artefact and nothing
# else: in the cluster the runner does its own actions/checkout and owns every file it then reads.
# The uid is immaterial to what is being verified here (which tools resolve on PATH, and how many
# assertions consequently run), so matching the host is the honest fix rather than relaxing the
# mount or chmod-ing the caller's tree.
#
# HOME is set explicitly because the caller's uid has no passwd entry inside the image; the suites
# override HOME with a hermetic mktemp -d anyway, but anything reading it before that would
# otherwise get `/`.
run_suite() { # <script-path-relative-to-repo>
	docker run --rm \
		--user "$(id -u):$(id -g)" \
		--env HOME=/tmp \
		--volume "$(cd "$repo" && pwd):/repo:ro" \
		--workdir /repo \
		"$image" \
		bash "/repo/$1"
}

# The summary line both suites end with is `PASS <n> / FAIL <n>`. Prints nothing if it is absent,
# which the callers treat as "the suite died before finishing".
summary_field() { # <output> <PASS|FAIL>
	local line
	line="$(grep -E '^PASS [0-9]+ / FAIL [0-9]+$' <<<"$1" | tail -1 || true)"
	[[ -n "$line" ]] || return 0
	if [[ "$2" == PASS ]]; then
		awk '{ print $2 }' <<<"$line"
	else
		awk '{ print $5 }' <<<"$line"
	fi
}

failed=0

# --- test_harness.sh -------------------------------------------------------------------------
echo "== scripts/tests/test_harness.sh (in $image)"
harness_out="$(run_suite scripts/tests/test_harness.sh || true)"
harness_pass="$(summary_field "$harness_out" PASS)"
harness_fail="$(summary_field "$harness_out" FAIL)"

if [[ -z "$harness_pass" ]]; then
	echo "  FAIL: no 'PASS n / FAIL n' summary line — the suite did not reach its end" >&2
	printf '%s\n' "$harness_out" | tail -30 >&2
	failed=1
else
	echo "  PASS $harness_pass / FAIL $harness_fail (expected $EXPECTED_HARNESS_PASS / $EXPECTED_HARNESS_FAIL)"
	if [[ "$harness_fail" != "$EXPECTED_HARNESS_FAIL" ]]; then
		echo "  FAIL: real assertion failures — this is a regression, not a missing tool" >&2
		grep -n '  FAIL: ' <<<"$harness_out" >&2 || true
		failed=1
	fi
	if [[ "$harness_pass" != "$EXPECTED_HARNESS_PASS" ]]; then
		echo "  FAIL: PASS count is $harness_pass, expected $EXPECTED_HARNESS_PASS" >&2
		# A lower count is almost always a tool missing from the image, and every such site
		# announces itself as a SKIP naming the tool. Print them: that list IS the fix.
		echo "  the skips below are the diagnosis — each names the tool the image still lacks:" >&2
		grep -n '  SKIP: ' <<<"$harness_out" >&2 || echo "  (no skips — the drift is elsewhere)" >&2
		failed=1
	fi
fi

# --- test_router.sh --------------------------------------------------------------------------
# Also wired to the pre-push stage, so it runs on the runner too. No PASS baseline is published for
# it in ci.yml, so FAIL is all we can honestly assert here.
echo "== router/proxmox/tests/test_router.sh (in $image)"
router_out="$(run_suite router/proxmox/tests/test_router.sh || true)"
router_pass="$(summary_field "$router_out" PASS)"
router_fail="$(summary_field "$router_out" FAIL)"

if [[ -z "$router_pass" ]]; then
	echo "  FAIL: no summary line — the suite did not reach its end" >&2
	printf '%s\n' "$router_out" | tail -30 >&2
	failed=1
else
	echo "  PASS $router_pass / FAIL $router_fail (expected FAIL $EXPECTED_ROUTER_FAIL)"
	if [[ "$router_fail" != "$EXPECTED_ROUTER_FAIL" ]]; then
		grep -n '  FAIL: ' <<<"$router_out" >&2 || true
		failed=1
	fi
	# Not fatal, but worth saying out loud: this suite skips its lint when shellcheck is absent,
	# and shellcheck absent from THIS image would be a real defect.
	if grep -q 'SKIP: shellcheck not on PATH' <<<"$router_out"; then
		echo "  FAIL: shellcheck is not on PATH in the image" >&2
		failed=1
	fi
fi

echo
if (( failed )); then
	echo "verify-harness: FAILED — the image is not acceptable"
	exit 1
fi
echo "verify-harness: OK — harness at full count, no failures"
exit 0
