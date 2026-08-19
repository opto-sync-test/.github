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
python3 -m json.tool "$fixture" >/dev/null
python3 -m json.tool "$expected" >/dev/null

"$subject" plan --report "$fixture" --output "$work/plan-a.json"
"$subject" plan --report "$fixture" --output "$work/plan-b.json"
cmp "$work/plan-a.json" "$work/plan-b.json"
cmp "$expected" "$work/plan-a.json"

jq '.gaps.graphOnly = ["example-unmapped/consumer"] | .gaps.unclassified = ["example-unmapped/consumer"]' "$fixture" > "$work/graph-gap.json"
expect_failure "$subject" plan --report "$work/graph-gap.json" --output "$work/graph-gap-plan.json"

jq '.inventory.missingGraphCount = 1' "$fixture" > "$work/missing-graph.json"
expect_failure "$subject" plan --report "$work/missing-graph.json" --output "$work/missing-graph-plan.json"

jq '.semantics.privateCoverage = "global"' "$fixture" > "$work/invalid-scope.json"
expect_failure "$subject" plan --report "$work/invalid-scope.json" --output "$work/invalid-scope-plan.json"

jq '.semantics.redirectsAllowed = true' "$fixture" > "$work/redirect-semantics.json"
expect_failure "$subject" plan --report "$work/redirect-semantics.json" --output "$work/redirect-semantics-plan.json"

jq '.inventory.packagesFetched = 2' "$fixture" > "$work/incomplete-index.json"
expect_failure "$subject" plan --report "$work/incomplete-index.json" --output "$work/incomplete-index-plan.json"

jq '.inventory.registryId = "bad registry"' "$fixture" > "$work/invalid-registry.json"
expect_failure "$subject" plan --report "$work/invalid-registry.json" --output "$work/invalid-registry-plan.json"

jq '.consumers |= map(if .repository == "sonus-auris/sonus-auris-sync" then .testRepository = null else . end)' "$fixture" > "$work/missing-test-repository.json"
expect_failure "$subject" plan --report "$work/missing-test-repository.json" --output "$work/missing.json"

jq '.consumers |= map(if .repository == "sonus-auris/sonus-auris-sync" then .repository = "../escape" else . end)' "$fixture" > "$work/path-coordinate.json"
expect_failure "$subject" plan --report "$work/path-coordinate.json" --output "$work/path-coordinate-plan.json"

jq '.consumers |= map(if .repository == "sonus-auris/sonus-auris-sync" then .linearIssue = "bad" else . end)' "$fixture" > "$work/invalid-linear-issue.json"
expect_failure "$subject" plan --report "$work/invalid-linear-issue.json" --output "$work/invalid-linear-issue-plan.json"

jq '.consumers += [.consumers[] | select(.repository == "sonus-auris/sonus-auris-sync")]' "$fixture" > "$work/duplicate-consumer.json"
expect_failure "$subject" plan --report "$work/duplicate-consumer.json" --output "$work/duplicate.json"

jq '.consumers |= map(.coverageStatus = "curated-only" | .minimumDepth = null)' "$fixture" > "$work/no-confirmed.json"
expect_failure "$subject" plan --report "$work/no-confirmed.json" --output "$work/empty.json"

expect_failure "$subject" plan --report "$fixture" --output "$work/too-many.json" --max-targets 1
expect_failure "$subject" dispatch --plan "$work/plan-a.json" --receipts "$work/no-token.json" --token-env MISSING_TOKEN
expect_failure "$subject" dispatch --plan "$work/plan-a.json" --receipts "$work/userinfo.json" --token-env TEST_DISPATCH_TOKEN --github-api-url 'https://api.github.com@attacker.example'
expect_failure "$subject" dispatch --plan "$work/plan-a.json" --receipts "$work/long-poll.json" --token-env TEST_DISPATCH_TOKEN --poll-interval-seconds 301
expect_failure "$subject" dispatch --plan "$work/plan-a.json" --receipts "$work/long-wait.json" --token-env TEST_DISPATCH_TOKEN --wait-timeout-seconds 21601

cat > "$work/fake-curl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
method='GET'
output=''
url=''
data=''
api_version=''
authorization=''
max_redirs=''
proto=''
connect_timeout=''
max_time=''
max_filesize=''
while (($#)); do
  case "$1" in
    --request) method="$2"; shift 2 ;;
    --output) output="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --header)
      case "$2" in
        'X-GitHub-Api-Version: '*) api_version="${2#X-GitHub-Api-Version: }" ;;
        'Authorization: Bearer '*) authorization="${2#Authorization: Bearer }" ;;
      esac
      shift 2
      ;;
    --data) data="$2"; shift 2 ;;
    --max-redirs) max_redirs="$2"; shift 2 ;;
    --proto) proto="$2"; shift 2 ;;
    --connect-timeout) connect_timeout="$2"; shift 2 ;;
    --max-time) max_time="$2"; shift 2 ;;
    --max-filesize) max_filesize="$2"; shift 2 ;;
    --silent|--show-error|--tlsv1.2) shift ;;
    --location) printf 'fake curl: redirect following is forbidden\n' >&2; exit 94 ;;
    https://*) url="$1"; shift ;;
    *) printf 'fake curl: unsupported argument %q\n' "$1" >&2; exit 90 ;;
  esac
done
[[ -n "$output" && -n "$url" ]] || exit 91
[[ "$api_version" == "${EXPECTED_API_VERSION:?}" ]] || exit 92
[[ "$authorization" == "${TEST_DISPATCH_TOKEN:?}" ]] || exit 93
[[ "$max_redirs" == '0' && "$proto" == '=https' ]] || exit 95
[[ "$connect_timeout" == '15' && "$max_time" == '120' ]] || exit 96
[[ "$max_filesize" =~ ^[1-9][0-9]*$ ]] || exit 97
printf '%s %s\n' "$method" "$url" >> "${FAKE_CURL_LOG:?}"

api_root="${url%%/repos/*}"
repository="${url#*/repos/}"
repository="${repository%%/actions/*}"
repository="${repository%%/commits/*}"
repository="${repository%%/contents/*}"
workflow_id="$(printf '%s' "$repository" | cksum | awk '{print $1}')"
run_id="$((workflow_id + 1000000))"
case "$repository" in
  sonus-auris/sonus-auris-e2e)
    expected_head_sha='1111111111111111111111111111111111111111'
    workflow_blob_sha='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    ;;
  voxletra/voxletra-e2e)
    expected_head_sha='2222222222222222222222222222222222222222'
    workflow_blob_sha='bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
    ;;
  *)
    expected_head_sha='3333333333333333333333333333333333333333'
    workflow_blob_sha='cccccccccccccccccccccccccccccccccccccccc'
    ;;
esac

state_key="$(printf '%s' "$repository" | tr '/.' '__')"
state_file="${FAKE_STATE_DIR:?}/commit-$state_key"
if [[ "$method" == 'GET' && "$url" == */commits/main ]]; then
  count=0
  [[ ! -f "$state_file" ]] || count="$(cat "$state_file")"
  count=$((count + 1))
  printf '%s' "$count" > "$state_file"
  if [[ "${FAKE_REF_MOVES_REPOSITORY:-}" == "$repository" && "$count" -ge 2 ]]; then
    printf '{"sha":"ffffffffffffffffffffffffffffffffffffffff"}\n' > "$output"
  else
    printf '{"sha":"%s"}\n' "$expected_head_sha" > "$output"
  fi
  printf '200'
  exit 0
fi

if [[ "${FAKE_OVERSIZED_REPOSITORY:-}" == "$repository" && "$method" == 'GET' && "$url" == */actions/workflows/opto-sync-wrapper-e2e.yml ]]; then
  python3 - "$output" <<'PY'
import pathlib, sys
pathlib.Path(sys.argv[1]).write_text('x' * 200000)
PY
  printf '200'
  exit 0
fi

if [[ "$method" == 'GET' && "$url" == */actions/workflows/opto-sync-wrapper-e2e.yml ]]; then
  if [[ -n "${FAKE_REDIRECT_REPOSITORY:-}" && "$repository" == "$FAKE_REDIRECT_REPOSITORY" ]]; then
    printf '{"message":"redirect"}\n' > "$output"
    printf '302'
    exit 0
  fi
  if [[ -n "${FAKE_MISSING_REPOSITORY:-}" && "$repository" == "$FAKE_MISSING_REPOSITORY" ]]; then
    printf '{"message":"not found"}\n' > "$output"
    printf '404'
    exit 0
  fi
  printf '{"id":%s,"path":".github/workflows/opto-sync-wrapper-e2e.yml","state":"active"}\n' "$workflow_id" > "$output"
  printf '200'
elif [[ "$method" == 'GET' && "$url" == */contents/.github/workflows/opto-sync-wrapper-e2e.yml\?ref=* ]]; then
  if [[ -n "${FAKE_WEAK_WORKFLOW:-}" ]]; then
    workflow_text=$'name: weakened\non:\n  workflow_dispatch:\n    inputs:\n      live_e2e:\n        type: boolean\njobs:\n  x:\n    steps:\n      - run: echo harmless\n'
  else
    workflow_text=$'name: opto-sync wrapper e2e\non:\n  workflow_dispatch:\n    inputs:\n      live_e2e:\n        type: boolean\njobs:\n  verify:\n    steps:\n      - run: |\n          OPTO_SYNC_REQUIRE_BROWSER=1 npm run test:browser\n          npm run test:node\n          cp product.e2e.test.mjs test/downstream-product.e2e.test.mjs\n'
  fi
  if [[ -n "${FAKE_INVALID_BASE64:-}" ]]; then
    content='not@@base64'
    size=10
  else
    content="$(printf '%s' "$workflow_text" | base64 | tr -d '\n')"
    size="$(printf '%s' "$workflow_text" | wc -c | tr -d ' ')"
  fi
  printf '{"type":"file","path":".github/workflows/opto-sync-wrapper-e2e.yml","encoding":"base64","size":%s,"sha":"%s","content":"%s"}\n' "$size" "$workflow_blob_sha" "$content" > "$output"
  printf '200'
elif [[ "$method" == 'POST' && "$url" == */actions/workflows/*/dispatches ]]; then
  jq -e '.ref == "main" and .inputs.live_e2e == true' <<<"$data" >/dev/null || exit 98
  requested_workflow_id="${url%/dispatches}"
  requested_workflow_id="${requested_workflow_id##*/actions/workflows/}"
  [[ "$requested_workflow_id" == "$workflow_id" ]] || exit 99
  if [[ "${FAKE_DISPATCH_FAILURE_REPOSITORY:-}" == "$repository" ]]; then
    printf '{"message":"dispatch failed"}\n' > "$output"
    printf '500'
    exit 0
  fi
  html_origin='https://github.com'
  [[ -z "${FAKE_BAD_HTML_ORIGIN:-}" ]] || html_origin='https://attacker.example'
  printf '{"workflow_run_id":%s,"run_url":"%s/repos/%s/actions/runs/%s","html_url":"%s/%s/actions/runs/%s"}\n' "$run_id" "$api_root" "$repository" "$run_id" "$html_origin" "$repository" "$run_id" > "$output"
  printf '200'
elif [[ "$method" == 'GET' && "$url" == */actions/runs/* ]]; then
  requested_run_id="${url##*/actions/runs/}"
  if [[ "${FAKE_POLL_FAILURE_REPOSITORY:-}" == "$repository" ]]; then
    printf '{"message":"poll failed"}\n' > "$output"
    printf '503'
    exit 0
  fi
  conclusion="${FAKE_RUN_CONCLUSION:-success}"
  run_head_sha="$expected_head_sha"
  if [[ -n "${FAKE_RUN_HEAD_DRIFT:-}" ]]; then
    run_head_sha='ffffffffffffffffffffffffffffffffffffffff'
  fi
  printf '{"id":%s,"workflow_id":%s,"event":"workflow_dispatch","status":"completed","conclusion":"%s","repository":{"full_name":"%s"},"run_attempt":1,"head_sha":"%s","head_branch":"main","path":".github/workflows/opto-sync-wrapper-e2e.yml@refs/heads/main","created_at":"2026-08-19T02:00:00Z","updated_at":"2026-08-19T02:01:00Z"}\n' "$requested_run_id" "$workflow_id" "$conclusion" "$repository" "$run_head_sha" > "$output"
  printf '200'
else
  printf '{"message":"not found"}\n' > "$output"
  printf '404'
fi
FAKE
chmod +x "$work/fake-curl"

export CURL_BIN="$work/fake-curl"
export FAKE_CURL_LOG="$work/fake-curl.log"
export FAKE_STATE_DIR="$work/fake-state"
export EXPECTED_API_VERSION='2026-03-10'
export TEST_DISPATCH_TOKEN='fixture-token-that-must-not-be-printed'
mkdir -p "$FAKE_STATE_DIR"

run_dispatch() {
  local receipts="$1"
  shift
  rm -rf "$FAKE_STATE_DIR"
  mkdir -p "$FAKE_STATE_DIR"
  : > "$FAKE_CURL_LOG"
  timeout 20 "$subject" dispatch \
    --plan "$work/plan-a.json" \
    --receipts "$receipts" \
    --token-env TEST_DISPATCH_TOKEN \
    --poll-interval-seconds 1 \
    --wait-timeout-seconds 10 \
    --max-api-response-bytes 100000 \
    "$@"
}

run_dispatch "$work/receipts.json"
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
  ([.dispatches[].testRepository] == ["sonus-auris/sonus-auris-e2e", "voxletra/voxletra-e2e"]) and
  (all(.dispatches[];
    .dispatchStatus == "accepted" and
    .runStatus == "completed" and
    .conclusion == "success" and
    (.workflowRunId | type == "number") and
    (.workflowBlobSha | test("^[0-9a-f]{40}$")) and
    (.workflowContentSha256 | test("^sha256:[0-9a-f]{64}$")) and
    (.expectedHeadSha | test("^[0-9a-f]{40}$")) and
    .headSha == .expectedHeadSha and
    .headBranch == "main" and
    .runPath == ".github/workflows/opto-sync-wrapper-e2e.yml@refs/heads/main"
  ))
' "$work/receipts.json" >/dev/null
[[ "$(wc -l < "$FAKE_CURL_LOG" | tr -d ' ')" == '12' ]] || fail 'expected six bounded API requests per target'
! grep -Fq "$TEST_DISPATCH_TOKEN" "$FAKE_CURL_LOG" || fail 'token leaked into the dispatch log'
! grep -Fq -- '--location' "$FAKE_CURL_LOG" || fail 'redirect-following option reached the request log'

export FAKE_REDIRECT_REPOSITORY='voxletra/voxletra-e2e'
expect_failure run_dispatch "$work/redirect-receipts.json"
jq -e '.status == "preflight-failed" and .acceptedCount == 0 and .targetCount == 2' "$work/redirect-receipts.json" >/dev/null
! grep -q '^POST ' "$FAKE_CURL_LOG" || fail 'dispatcher followed or bypassed a preflight redirect'
unset FAKE_REDIRECT_REPOSITORY

export FAKE_MISSING_REPOSITORY='voxletra/voxletra-e2e'
expect_failure run_dispatch "$work/preflight-failure.json"
jq -e '.status == "preflight-failed" and .acceptedCount == 0 and .pendingCount == 2' "$work/preflight-failure.json" >/dev/null
! grep -q '^POST ' "$FAKE_CURL_LOG" || fail 'dispatcher sent a workflow before every target passed preflight'
unset FAKE_MISSING_REPOSITORY

export FAKE_WEAK_WORKFLOW='1'
expect_failure run_dispatch "$work/weak-workflow.json"
jq -e '.status == "preflight-failed" and .acceptedCount == 0' "$work/weak-workflow.json" >/dev/null
! grep -q '^POST ' "$FAKE_CURL_LOG" || fail 'dispatcher sent a workflow whose parsed source failed conformance'
unset FAKE_WEAK_WORKFLOW

export FAKE_INVALID_BASE64='1'
expect_failure run_dispatch "$work/invalid-base64.json"
jq -e '.status == "preflight-failed" and .acceptedCount == 0' "$work/invalid-base64.json" >/dev/null
unset FAKE_INVALID_BASE64

export FAKE_OVERSIZED_REPOSITORY='sonus-auris/sonus-auris-e2e'
expect_failure run_dispatch "$work/oversized.json"
jq -e '.status == "preflight-failed" and .acceptedCount == 0' "$work/oversized.json" >/dev/null
unset FAKE_OVERSIZED_REPOSITORY

export FAKE_REF_MOVES_REPOSITORY='voxletra/voxletra-e2e'
expect_failure run_dispatch "$work/ref-moved.json"
jq -e '.status == "dispatch-failed" and .acceptedCount == 1 and .targetCount == 2' "$work/ref-moved.json" >/dev/null
unset FAKE_REF_MOVES_REPOSITORY

export FAKE_DISPATCH_FAILURE_REPOSITORY='voxletra/voxletra-e2e'
expect_failure run_dispatch "$work/dispatch-failed.json"
jq -e '.status == "dispatch-failed" and .acceptedCount == 1 and .targetCount == 2' "$work/dispatch-failed.json" >/dev/null
unset FAKE_DISPATCH_FAILURE_REPOSITORY

export FAKE_BAD_HTML_ORIGIN='1'
expect_failure run_dispatch "$work/html-origin.json"
jq -e '.status == "dispatch-failed" and .acceptedCount == 0' "$work/html-origin.json" >/dev/null
unset FAKE_BAD_HTML_ORIGIN

export FAKE_RUN_HEAD_DRIFT='1'
expect_failure run_dispatch "$work/head-drift.json"
jq -e '.status == "poll-failed" and .acceptedCount == 2 and .dispatches[0].runStatus == "contract-violation"' "$work/head-drift.json" >/dev/null
unset FAKE_RUN_HEAD_DRIFT

export FAKE_POLL_FAILURE_REPOSITORY='sonus-auris/sonus-auris-e2e'
expect_failure run_dispatch "$work/poll-failed.json"
jq -e '.status == "poll-failed" and .acceptedCount == 2 and .dispatches[0].runStatus == "lookup-failed"' "$work/poll-failed.json" >/dev/null
unset FAKE_POLL_FAILURE_REPOSITORY

export FAKE_RUN_CONCLUSION='failure'
expect_failure run_dispatch "$work/failure-receipts.json"
jq -e '
  .status == "failed" and
  .completedCount == 2 and
  .successfulCount == 0 and
  .failedCount == 2 and
  .pendingCount == 0 and
  (all(.dispatches[]; .conclusion == "failure"))
' "$work/failure-receipts.json" >/dev/null
unset FAKE_RUN_CONCLUSION

! grep -R -Fq "$TEST_DISPATCH_TOKEN" "$work"/*.json "$FAKE_CURL_LOG" || fail 'token leaked into durable evidence'
printf 'dispatch contract test: PASS\n'
