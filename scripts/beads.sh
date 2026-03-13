#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
	cat <<'EOF'
Usage:
  ./scripts/beads.sh status
  ./scripts/beads.sh check
  ./scripts/beads.sh run <bd args...>

Commands:
  status  Print whether Beads is enabled for this repo and why.
  check   Exit 0 if Beads is healthy for this repo, 1 otherwise.
  run     Execute a bd command only if Beads is healthy. Otherwise print a
          short skip message and exit 0 so agents do not get stuck on setup.
EOF
}

reason_lines() {
	if ! command -v bd >/dev/null 2>&1; then
		echo "- bd CLI is not installed"
	fi

	if [[ ! -d "$ROOT/.beads" ]]; then
		echo "- this repo has no .beads directory"
	fi

	if command -v bd >/dev/null 2>&1 && [[ -d "$ROOT/.beads" ]]; then
		if ! (cd "$ROOT" && bd context >/dev/null 2>&1); then
			echo "- bd context failed for this repo"
		fi
	fi
}

beads_ready() {
	command -v bd >/dev/null 2>&1 &&
		[[ -d "$ROOT/.beads" ]] &&
		(cd "$ROOT" && bd context >/dev/null 2>&1)
}

status_cmd() {
	if beads_ready; then
		echo "beads: enabled"
		return 0
	fi

	echo "beads: disabled"
	reason_lines
	return 0
}

check_cmd() {
	beads_ready
}

run_cmd() {
	if [[ $# -eq 0 ]]; then
		echo "beads: missing bd arguments" >&2
		usage >&2
		return 2
	fi

	if beads_ready; then
		cd "$ROOT"
		exec bd "$@"
	fi

	echo "beads: disabled for this repo; skipping 'bd $*'" >&2
	reason_lines >&2
	return 0
}

main() {
	local cmd="${1:-status}"
	case "$cmd" in
	status)
		status_cmd
		;;
	check)
		check_cmd
		;;
	run)
		shift
		run_cmd "$@"
		;;
	help|-h|--help)
		usage
		;;
	*)
		echo "beads: unknown command '$cmd'" >&2
		usage >&2
		return 2
		;;
	esac
}

main "$@"
