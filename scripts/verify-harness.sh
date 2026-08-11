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
# Measured on ubuntu-latest and recorded in homelab-infra/.github/workflows/ci.yml, which also says:
# "Do not make it green by skipping a suite or relaxing an assertion." That applies here too — if
# this number moves, find out why before editing it.
#
# TWO REASONS IT CAN MOVE, AND THEY ARE OPPOSITES:
#   1. A TOOL WENT MISSING FROM THIS IMAGE. The count goes DOWN, `_skip` sites fire, and the skip
#      list printed on failure names exactly what to add back. This is the failure the gate exists
#      for, and the fix is in the Dockerfile — never in this number.
#   2. homelab-infra GREW ITS SUITE. The count goes UP, with no skips. Nothing is wrong with the
#      image; the number here is simply stale, and bumping it deliberately IS the correct response.
#      All three bumps so far were this case: 1897 -> 1902 (homelab-infra Test 90, five static rows
#      pinning that pulumi-run.sh installs with `npm ci`), 1902 -> 1973 (the ARC GitHub App
#      credential value becoming Pulumi-owned, +71), 1973 -> 2052 (+79, a CORRECTION of a
#      number that had gone stale — see the gap note below), and 2052 -> 2096 (+44, pinning
#      load_env_file's value-trimming contract — the first bump that genuinely belongs to the
#      commit recording it rather than being a correction of drift).
#
# The cross-repo coupling is real and worth naming: a change made entirely in homelab-infra turns
# this gate red. Bump the two together. The gate stays an absolute count rather than, say, an A/B
# against a stock-image run, because an absolute number is the only form that cannot be satisfied by
# both sides eroding at once — at the cost of this maintenance.
#
# THE 1973 BUMP SHOWS WHY "TOGETHER" IS LOAD-BEARING: it merged in homelab-infra with this file
# untouched, and NOTHING WENT RED, because this gate only runs when something pushes to THIS repo.
# The breakage sat armed and invisible until the next build here. A deferred failure in another
# repository is the worst shape this coupling can take, and no amount of care in homelab-infra's
# review catches it — only bumping both in the same session does.
#
# THE GAP MOVED ON THE THIRD BUMP: 264 -> 286 (1709/1973 -> 1766/2052), after surviving the first
# two unchanged. The previous note said that means the new rows are tool-dependent and to investigate
# before bumping, so that was done rather than assumed — the stock figure was RE-MEASURED, not
# derived as 1709+79.
#
# Method, because the obvious shortcut is wrong: the five tools test_harness.sh probes for
# (make, shellcheck, kubectl, curl, bao) must be genuinely ABSENT from PATH — note the line wrap,
# a comment line starting "# shellcheck" is parsed as a DIRECTIVE and fails SC1073. It symlink-farms
# every other binary into a temp dir and runs against that. A stub exiting 127 is still FOUND by
# `command -v`, so the gated blocks execute and FAIL rather than degrading to `_skip`; that
# misreading scores 1937/101 and means nothing.
#
# THE GAP HELD ON THE FOURTH BUMP: still 286 (1766/2052 -> 1810/2096). All 44 new rows are ungated,
# which 1766+44 = 1810 confirms exactly. A gap that holds while the total rises is the boring, good
# outcome — the suite grew without growing its tool surface, so nothing about THIS image changed.
#
# RESULT, CORRECTED — the third bump recorded "`make` alone accounts for the WHOLE gap; omitting only
# `make` scores 1766, identical to omitting all five, so the other four gate nothing on top of it".
# THAT DOES NOT REPRODUCE. Re-measured on the 2096 commit, one run per PATH:
#
#     full 2096 | all five absent 1810 (gap 286) | only make absent 1824 (make: 272)
#     | only the other four absent 2082 (those four: 14)
#
# 272 + 14 = 286 EXACTLY — the gates are DISJOINT, not nested, and that additivity is what makes the
# numbers self-checking. The old reading is therefore believed to be a bad measurement, not a real
# structural change. Do not restore the nesting claim without reproducing it.
#
# THIS IMAGE IS STILL NOT MISSING ANYTHING: it ships make, which is why it scores the full 2096.
# `make` still dominates the gap (272 of 286), so the reason this image exists is unchanged.
readonly EXPECTED_HARNESS_PASS=2096
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
		# THE DIRECTION IS THE DIAGNOSIS, so say which one this is rather than printing one
		# explanation for both. The original message asserted "each names the tool the image still
		# lacks" unconditionally, and that is wrong in TWO different ways, not one.
		#
		# THREE CASES, and the third is the one that bit during this very change. `_skip` sites are
		# what a missing tool produces, so their presence — not the direction alone — is what
		# separates "the image is broken" from "the two repos are out of step":
		#
		#   count UP                  homelab-infra grew its suite; this baseline is stale.
		#   count DOWN, skips present a tool is missing from the image. The skip list IS the fix.
		#   count DOWN, no skips      the checked-out homelab-infra is OLDER than this baseline
		#                             expects. Nothing is wrong with the image at all.
		#
		# That last case is not hypothetical: this file's own bump to 1902 was committed while
		# homelab-infra's PR was still unmerged, so CI checked out a main that still scored 1897 and
		# the gate printed the missing-tool text plus one unrelated pre-existing SKIP. Perfectly
		# misleading, and precisely the failure this block was written to remove — just in the
		# direction that was not anticipated. A gate whose failure text sends you to the wrong repo
		# costs more than a gate with no text.
		if (( harness_pass > EXPECTED_HARNESS_PASS )); then
			echo "  the count went UP by $(( harness_pass - EXPECTED_HARNESS_PASS )). That is homelab-infra adding" >&2
			echo "  assertions, NOT a defect in this image — a missing tool can only lower the count." >&2
			echo "  Confirm against homelab-infra's recorded baseline, then bump EXPECTED_HARNESS_PASS here." >&2
		elif grep -q '  SKIP: .*not on PATH' <<<"$harness_out"; then
			# Missing-tool skips are the ones that name a tool and PATH. Anchoring on that phrase
			# rather than on 'SKIP:' matters: the suite carries unrelated permanent skips (e.g. the
			# F18 kubeconfig-merge one), and matching those would resurrect the wrong diagnosis.
			echo "  the count is LOW and tool skips fired — each names the tool the image still lacks:" >&2
			grep -n '  SKIP: .*not on PATH' <<<"$harness_out" >&2
			echo "  Fix this in the Dockerfile. Never by lowering EXPECTED_HARNESS_PASS." >&2
		else
			echo "  the count is LOW but NO tool skip fired, so nothing is missing from this image." >&2
			echo "  The usual cause is a version skew between the repos: the homelab-infra checked out" >&2
			echo "  here is OLDER than the $EXPECTED_HARNESS_PASS this file expects — which is exactly what a" >&2
			echo "  baseline bump landing before its homelab-infra counterpart looks like. Check that" >&2
			echo "  repo's main, not the Dockerfile." >&2
			echo "  (all skips, for reference:)" >&2
			grep -n '  SKIP: ' <<<"$harness_out" >&2 || echo "  (none)" >&2
		fi
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
