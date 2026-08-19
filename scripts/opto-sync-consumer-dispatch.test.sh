#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
subject="$root/scripts/opto-sync-consumer-dispatch.sh"
fixture="$root/architecture/fixtures/opto-sync-consumer-impact.v1.json"
expected="$root/architecture/fixtures/opto-sync-consumer-execution-plan.v1.json"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'dispatch contract test: %s\n' "$*" >&2
  exit 1
}

expect_failure() {
  if "$@" >"$work/expected-failure.stdout" 2>"$work/expected-failure.stderr"; then
    fail "command unexpectedly succeeded: $*"
  fi
}

bash -n "$subject" "$root"/scripts/lib/opto-sync-consumer-*.sh

"$subject" plan --report "$fixture" --output "$work/plan-a.json"
"$subject" plan --report "$fixture" --output "$work/plan-b.json"
cmp "$work/plan-a.json" "$work/plan-b.json"
cmp "$expected" "$work/plan-a.json"

jq '.gaps.graphOnly = ["example-unmapped/consumer"] | .gaps.unclassified = ["example-unmapped/consumer"]' \
  "$fixture" > "$work/graph-gap.json"
expect_failure "$subject" plan \
  --report "$work/graph-gap.json" --output "$work/graph-gap-plan.json"

jq '.inventory.missingGraphCount = 1' \
  "$fixture" > "$work/missing-graph.json"
expect_failure "$subject" plan \
  --report "$work/missing-graph.json" --output "$work/missing-graph-plan.json"

jq '.semantics.privateCoverage = "global"' \
  "$fixture" > "$work/invalid-scope.json"
expect_failure "$subject" plan \
  --report "$work/invalid-scope.json" --output "$work/invalid-scope-plan.json"

jq '.consumers |= map(if .repository == "sonus-auris/sonus-auris-sync" then .testRepository = null else . end)' \
  "$fixture" > "$work/missing-test-repository.json"
expect_failure "$subject" plan \
  --report "$work/missing-test-repository.json" --output "$work/missing.json"

jq '.consumers |= map(if .repository == "sonus-auris/sonus-auris-sync" then .linearIssue = "bad" else . end)' \
  "$fixture" > "$work/invalid-linear-issue.json"
expect_failure "$subject" plan \
  --report "$work/invalid-linear-issue.json" --output "$work/invalid-linear-issue-plan.json"

jq '.consumers += [.consumers[] | select(.repository == "sonus-auris/sonus-auris-sync")]' \
  "$fixture" > "$work/duplicate-consumer.json"
expect_failure "$subject" plan \
  --report "$work/duplicate-consumer.json" --output "$work/duplicate.json"

jq '.consumers |= map(.coverageStatus = "curated-only" | .minimumDepth = null)' \
  "$fixture" > "$work/no-confirmed.json"
expect_failure "$subject" plan \
  --report "$work/no-confirmed.json" --output "$work/empty.json"

expect_failure "$subject" plan \
  --report "$fixture" --output "$work/too-many.json" --max-targets 1
expect_failure "$subject" dispatch \
  --plan "$work/plan-a.json" --receipts "$work/no-token.json" --token-env MISSING_TOKEN

cat > "$work/fake-curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
method='GET'
output=''
url=''
data=''
api_version=''
while (($#)); do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --header)
      case "$2" in
        'X-GitHub-Api-Version: '*) api_version="${2#X-GitHub-Api-Version: }" ;;
      esac
      shift 2
      ;;
    --data) data="$2"; shift 2 ;;
    --silent|--show-error|--location) shift ;;
    https://*) url="$1"; shift ;;
    *) printf 'fake curl: unsupported argument %q\n' "$1" >&2; exit 90 ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 91
[[ "$api_version" == "${EXPECTED_API_VERSION:?}" ]] || {
  printf 'fake curl: unexpected API version %q\n' "$api_version" >&2
  exit 92
}
printf '%s %s\n' "$method" "$url" >> "${FAKE_CURL_LOG:?}"

api_root="${url%%/repos/*}"
repository="${url#*/repos/}"
repository="${repository%%/actions/*}"
workflow_id="$(printf '%s' "$repository" | cksum | awk '{print $1}')"
run_id="$((workflow_id + 1000000))"

if [[ "$method" == 'GET' && "$url" == */actions/workflows/opto-sync-wrapper-e2e.yml ]]; then
  if [[ -n "${FAKE_MISSING_REPOSITORY:-}" && "$repository" == "$FAKE_MISSING_REPOSITORY" ]]; then
    printf '{"message":"not found"}\n' > "$output"
    printf '404'
    exit 0
  fi
  printf '{"id":%s,"path":".github/workflows/opto-sync-wrapper-e2e.yml","state":"active"}\n' \
    "$workflow_id" > "$output"
  printf '200'
elif [[ "$method" == 'POST' && "$url" == */actions/workflows/opto-sync-wrapper-e2e.yml/dispatches ]]; then
  jq -e '.ref == "main" and .inputs.live_e2e == true' <<<"$data" >/dev/null || exit 93
  printf '{"workflow_run_id":%s,"run_url":"%s/repos/%s/actions/runs/%s","html_url":"https://github.com/%s/actions/runs/%s"}\n' \
    "$run_id" "$api_root" "$repository" "$run_id" "$repository" "$run_id" > "$output"
  printf '200'
elif [[ "$method" == 'GET' && "$url" == */actions/runs/* ]]; then
  requested_run_id="${url##*/actions/runs/}"
  conclusion="${FAKE_RUN_CONCLUSION:-success}"
  printf '{"id":%s,"workflow_id":%s,"event":"workflow_dispatch","status":"completed","conclusion":"%s","repository":{"full_name":"%s"},"run_attempt":1,"head_sha":"0123456789012345678901234567890123456789","created_at":"2026-08-19T02:00:00Z","updated_at":"2026-08-19T02:01:00Z"}\n' \
    "$requested_run_id" "$workflow_id" "$conclusion" "$repository" > "$output"
  printf '200'
else
  printf '{"message":"not found"}\n' > "$output"
  printf '404'
fi
FAKE
chmod +x "$work/fake-curl"

export CURL_BIN="$work/fake-curl"
export FAKE_CURL_LOG="$work/fake-curl.log"
export EXPECTED_API_VERSION='2026-03-10'
export TEST_DISPATCH_TOKEN='fixture-token-that-must-not-be-printed'
"$subject" dispatch \
  --plan "$work/plan-a.json" \
  --receipts "$work/receipts.json" \
  --token-env TEST_DISPATCH_TOKEN \
  --poll-interval-seconds 1 \
  --wait-timeout-seconds 10

jq -e '
  .schema == "opto-sync/consumer-dispatch-receipts/v1" and
  .apiVersion == "2026-03-10" and
  .status == "completed" and
  .targetCount == 2 and
  .acceptedCount == 2 and
  .completedCount == 2 and
  .successfulCount == 2 and
  .failedCount == 0 and
  .pendingCount == 0 and
  ([.dispatches[].testRepository] == [
    "sonus-auris/sonus-auris-e2e",
    "voxletra/voxletra-e2e"
  ]) and
  (all(.dispatches[];
    .dispatchStatus == "accepted" and
    .runStatus == "completed" and
    .conclusion == "success" and
    (.workflowRunId | type == "number")
  ))
' "$work/receipts.json" >/dev/null
[[ "$(wc -l < "$FAKE_CURL_LOG" | tr -d ' ')" == '6' ]] || \
  fail 'expected two workflow lookups, two dispatches, and two exact run polls'
! grep -Fq "$TEST_DISPATCH_TOKEN" "$FAKE_CURL_LOG" || fail 'token leaked into the dispatch log'

: > "$FAKE_CURL_LOG"
export FAKE_MISSING_REPOSITORY='voxletra/voxletra-e2e'
expect_failure "$subject" dispatch \
  --plan "$work/plan-a.json" \
  --receipts "$work/preflight-failure.json" \
  --token-env TEST_DISPATCH_TOKEN \
  --poll-interval-seconds 1 \
  --wait-timeout-seconds 10
! grep -q '^POST ' "$FAKE_CURL_LOG" || fail 'dispatcher sent a workflow before every target passed preflight'
unset FAKE_MISSING_REPOSITORY

: > "$FAKE_CURL_LOG"
export FAKE_RUN_CONCLUSION='failure'
expect_failure "$subject" dispatch \
  --plan "$work/plan-a.json" \
  --receipts "$work/failure-receipts.json" \
  --token-env TEST_DISPATCH_TOKEN \
  --poll-interval-seconds 1 \
  --wait-timeout-seconds 10
jq -e '
  .status == "failed" and
  .completedCount == 2 and
  .successfulCount == 0 and
  .failedCount == 2 and
  .pendingCount == 0 and
  (all(.dispatches[]; .conclusion == "failure"))
' "$work/failure-receipts.json" >/dev/null
unset FAKE_RUN_CONCLUSION

printf 'dispatch contract test: PASS\n'
