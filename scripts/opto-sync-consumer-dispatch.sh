#!/usr/bin/env bash
set -euo pipefail

readonly OPTO_SYNC_CONSUMER_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/opto-sync-consumer-common.sh
source "$OPTO_SYNC_CONSUMER_SCRIPT_DIR/lib/opto-sync-consumer-common.sh"
# shellcheck source=scripts/lib/opto-sync-consumer-plan.sh
source "$OPTO_SYNC_CONSUMER_SCRIPT_DIR/lib/opto-sync-consumer-plan.sh"
# shellcheck source=scripts/lib/opto-sync-consumer-dispatch.sh
source "$OPTO_SYNC_CONSUMER_SCRIPT_DIR/lib/opto-sync-consumer-dispatch.sh"

main() {
  [[ $# -ge 1 ]] || { usage; exit 2; }
  local command="$1"
  shift
  case "$command" in
    plan) plan_command "$@" ;;
    dispatch) dispatch_command "$@" ;;
    -h|--help|help) usage ;;
    *) usage; die "unsupported command: $command" ;;
  esac
}

main "$@"
