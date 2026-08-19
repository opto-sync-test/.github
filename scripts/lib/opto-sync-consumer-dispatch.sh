# shellcheck shell=bash
dispatch_command() {
  local plan='' receipts='' token_env='OPTO_SYNC_TEST_DISPATCH_TOKEN'
  local api_url="${GITHUB_API_URL:-$DEFAULT_GITHUB_API_URL}"
  local api_version="${GITHUB_API_VERSION:-$DEFAULT_GITHUB_API_VERSION}"
  local poll_interval="$DEFAULT_POLL_INTERVAL_SECONDS"
  local wait_timeout="$DEFAULT_WAIT_TIMEOUT_SECONDS"
  local max_api_response_bytes="$DEFAULT_MAX_API_RESPONSE_BYTES"

  while (($#)); do
    case "$1" in
      --plan) [[ $# -ge 2 ]] || die '--plan requires a value'; plan="$2"; shift 2 ;;
      --receipts) [[ $# -ge 2 ]] || die '--receipts requires a value'; receipts="$2"; shift 2 ;;
      --token-env) [[ $# -ge 2 ]] || die '--token-env requires a value'; token_env="$2"; shift 2 ;;
      --github-api-url) [[ $# -ge 2 ]] || die '--github-api-url requires a value'; api_url="$2"; shift 2 ;;
      --github-api-version) [[ $# -ge 2 ]] || die '--github-api-version requires a value'; api_version="$2"; shift 2 ;;
      --poll-interval-seconds) [[ $# -ge 2 ]] || die '--poll-interval-seconds requires a value'; poll_interval="$2"; shift 2 ;;
      --wait-timeout-seconds) [[ $# -ge 2 ]] || die '--wait-timeout-seconds requires a value'; wait_timeout="$2"; shift 2 ;;
      --max-api-response-bytes) [[ $# -ge 2 ]] || die '--max-api-response-bytes requires a value'; max_api_response_bytes="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "unsupported dispatch argument: $1" ;;
    esac
  done

  [[ -n "$plan" && -f "$plan" ]] || die '--plan must name an existing JSON file'
  [[ -n "$receipts" ]] || die '--receipts is required'
  [[ "$token_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die '--token-env must be a valid environment variable name'
  [[ "$api_version" == "$DEFAULT_GITHUB_API_VERSION" ]] || \
    die "--github-api-version must be $DEFAULT_GITHUB_API_VERSION"
  require_bounded_positive_integer "$poll_interval" '--poll-interval-seconds' "$MAX_POLL_INTERVAL_SECONDS"
  require_bounded_positive_integer "$wait_timeout" '--wait-timeout-seconds' "$MAX_WAIT_TIMEOUT_SECONDS"
  require_bounded_positive_integer "$max_api_response_bytes" '--max-api-response-bytes' 52428800
  require_command jq
  require_command python3
  require_command ruby

  local normalized_output
  if ! normalized_output="$(normalize_github_api_url "$api_url" 2>&1)"; then
    die "$normalized_output"
  fi
  local -a normalized_parts=()
  mapfile -t normalized_parts <<< "$normalized_output"
  [[ "${#normalized_parts[@]}" == 2 ]] || die 'GitHub API URL normalization returned an invalid result'
  api_url="${normalized_parts[0]}"
  local github_web_origin="${normalized_parts[1]}"

  CURL_BIN="${CURL_BIN:-curl}"
  command -v "$CURL_BIN" >/dev/null 2>&1 || [[ -x "$CURL_BIN" ]] || die "curl implementation is unavailable: $CURL_BIN"
  DISPATCH_TOKEN="${!token_env-}"
  validate_secret_header_value "$DISPATCH_TOKEN" "dispatch token environment variable $token_env"
  GITHUB_API_URL="$api_url"
  GITHUB_WEB_ORIGIN="$github_web_origin"
  GITHUB_API_VERSION="$api_version"
  CONNECT_TIMEOUT_SECONDS="$DEFAULT_CONNECT_TIMEOUT_SECONDS"
  REQUEST_TIMEOUT_SECONDS="$DEFAULT_REQUEST_TIMEOUT_SECONDS"
  MAX_API_RESPONSE_BYTES="$max_api_response_bytes"

  jq --exit-status \
    --arg schema "$PLAN_SCHEMA" \
    --arg root_package "$ROOT_PACKAGE" \
    --arg package_index_scope "$DECLARED_PACKAGE_INDEX_SCOPE" \
    --arg private_coverage "$DECLARED_PRIVATE_COVERAGE" \
    --arg inventory_consistency "$DECLARED_INVENTORY_CONSISTENCY" \
    --arg workflow_file "$DEFAULT_WORKFLOW_FILE" \
    --arg workflow_ref "$DEFAULT_WORKFLOW_REF" '
      def component:
        type == "string" and length >= 1 and length <= 100 and
        test("^[A-Za-z0-9_.-]+$") and . != "." and . != "..";
      def coordinate:
        type == "string" and length <= 201 and
        (split("/") as $parts | ($parts | length) == 2 and all($parts[]; component));
      def registry_id:
        type == "string" and length >= 1 and length <= 256 and
        test("^[A-Za-z0-9][A-Za-z0-9._:/-]*$");
      def issue_id:
        type == "string" and test("^[A-Z][A-Z0-9]+-[1-9][0-9]*$");
      def classification:
        type == "string" and IN("exact-pin", "package-release", "adapted-concept", "candidate");
      .schema == $schema and
      .source.root == $root_package and
      (.source.registryId | registry_id) and
      .source.versionPolicy == "all-visible" and
      .source.graphView == "declared" and
      .source.resolution == "unresolved-requirements" and
      .source.packageIndexScope == $package_index_scope and
      .source.privateCoverage == $private_coverage and
      .source.inventoryConsistency == $inventory_consistency and
      .source.redirectsAllowed == false and
      (.source.inventoryDigest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
      .workflow.file == $workflow_file and
      .workflow.path == (".github/workflows/" + $workflow_file) and
      .workflow.ref == $workflow_ref and
      .workflow.inputs == {live_e2e: true} and
      .completion == {required: true, successfulConclusions: ["success"]} and
      (.targets | type == "array" and length >= 1 and length <= 50) and
      (.targetCount == (.targets | length)) and
      (.consumerCount == ([.targets[].consumers[]] | length)) and
      ([.targets[].testRepository] | length == (unique | length)) and
      ([.targets[].consumers[].repository] | length == (unique | length)) and
      (all(.targets[];
        (.testRepository | coordinate) and
        (.consumers | type == "array" and length >= 1) and
        all(.consumers[];
          (.repository | coordinate) and
          (.minimumDepth | type == "number" and floor == . and . >= 1) and
          (.adoptionClassification | classification) and
          (.linearIssue | issue_id)
        )
      ))
    ' "$plan" >/dev/null || die 'execution plan failed dispatch validation'

  mkdir -p "$(dirname "$receipts")"
  local work_dir plan_digest workflow_file workflow_path workflow_ref target_count
  local preflight_ndjson preflight_json dispatches_ndjson dispatches_json runs_ndjson runs_json
  work_dir="$(mktemp -d)"
  trap 'rm -rf "${work_dir:-}"' RETURN EXIT
  preflight_ndjson="$work_dir/preflight.ndjson"
  preflight_json="$work_dir/preflight.json"
  dispatches_ndjson="$work_dir/dispatches.ndjson"
  dispatches_json="$work_dir/dispatches.json"
  runs_ndjson="$work_dir/runs.ndjson"
  runs_json="$work_dir/runs.json"
  : > "$preflight_ndjson"
  : > "$dispatches_ndjson"
  : > "$runs_ndjson"
  printf '[]\n' > "$preflight_json"
  printf '[]\n' > "$dispatches_json"
  printf '[]\n' > "$runs_json"
  plan_digest="$(sha256_file "$plan")"
  workflow_file="$(jq -r '.workflow.file' "$plan")"
  workflow_path="$(jq -r '.workflow.path' "$plan")"
  workflow_ref="$(jq -r '.workflow.ref' "$plan")"
  target_count="$(jq -r '.targetCount' "$plan")"

  refresh_collections() {
    if [[ -s "$preflight_ndjson" ]]; then jq -s --sort-keys 'sort_by(.testRepository)' "$preflight_ndjson" > "$preflight_json"; else printf '[]\n' > "$preflight_json"; fi
    if [[ -s "$dispatches_ndjson" ]]; then jq -s --sort-keys 'sort_by(.testRepository)' "$dispatches_ndjson" > "$dispatches_json"; else printf '[]\n' > "$dispatches_json"; fi
    if [[ -s "$runs_ndjson" ]]; then jq -s --sort-keys 'sort_by(.testRepository)' "$runs_ndjson" > "$runs_json"; else printf '[]\n' > "$runs_json"; fi
  }

  dispatch_fail() {
    local status="$1" reason="$2"
    refresh_collections
    write_receipts "$dispatches_json" "$runs_json" "$receipts" "$status" \
      "$plan_digest" "$api_url" "$api_version" "$target_count" "$reason"
    die "$reason; receipts were written"
  }

  local index=0 target repository metadata_body metadata_code workflow_state workflow_metadata_path workflow_id
  local ref_body ref_code expected_head_sha contents_body contents_code workflow_blob_sha workflow_source
  local workflow_content_sha256
  while IFS= read -r target; do
    index=$((index + 1))
    repository="$(jq -r '.testRepository' <<<"$target")"

    metadata_body="$work_dir/workflow-${index}.json"
    if ! metadata_code="$(curl_request GET \
      "$api_url/repos/$repository/actions/workflows/$workflow_file" \
      "$metadata_body")"; then
      dispatch_fail 'preflight-failed' "$repository: workflow lookup transport or size failure"
    fi
    [[ "$metadata_code" == '200' ]] || dispatch_fail 'preflight-failed' "$repository: workflow lookup returned HTTP $metadata_code"
    if ! jq --exit-status --arg path "$workflow_path" '
      .state == "active" and .path == $path and
      (.id | type == "number" and floor == . and . >= 1)
    ' "$metadata_body" >/dev/null; then
      dispatch_fail 'preflight-failed' "$repository: workflow metadata violated the execution contract"
    fi
    workflow_state="$(jq -r '.state' "$metadata_body")"
    workflow_metadata_path="$(jq -r '.path' "$metadata_body")"
    workflow_id="$(jq -r '.id' "$metadata_body")"
    [[ "$workflow_state" == 'active' && "$workflow_metadata_path" == "$workflow_path" ]] || \
      dispatch_fail 'preflight-failed' "$repository: target workflow is inactive or at an unexpected path"

    ref_body="$work_dir/ref-${index}.json"
    if ! ref_code="$(curl_request GET "$api_url/repos/$repository/commits/$workflow_ref" "$ref_body")"; then
      dispatch_fail 'preflight-failed' "$repository: workflow ref lookup transport or size failure"
    fi
    [[ "$ref_code" == '200' ]] || dispatch_fail 'preflight-failed' "$repository: workflow ref lookup returned HTTP $ref_code"
    expected_head_sha="$(jq -r '.sha // empty' "$ref_body")"
    [[ "$expected_head_sha" =~ ^[0-9a-f]{40}$ ]] || \
      dispatch_fail 'preflight-failed' "$repository: workflow ref did not resolve to a full lowercase commit SHA"

    contents_body="$work_dir/workflow-contents-${index}.json"
    if ! contents_code="$(curl_request GET \
      "$api_url/repos/$repository/contents/$workflow_path?ref=$expected_head_sha" \
      "$contents_body")"; then
      dispatch_fail 'preflight-failed' "$repository: immutable workflow content lookup transport or size failure"
    fi
    [[ "$contents_code" == '200' ]] || dispatch_fail 'preflight-failed' "$repository: immutable workflow content lookup returned HTTP $contents_code"
    workflow_blob_sha="$(jq -r '.sha // empty' "$contents_body")"
    [[ "$workflow_blob_sha" =~ ^[0-9a-f]{40}$ ]] || \
      dispatch_fail 'preflight-failed' "$repository: immutable workflow content has no full blob SHA"
    if ! jq --exit-status --arg path "$workflow_path" --argjson maximum "$DEFAULT_MAX_WORKFLOW_SOURCE_BYTES" '
      .type == "file" and .path == $path and .encoding == "base64" and
      (.size | type == "number" and floor == . and . > 0 and . <= $maximum) and
      (.content | type == "string" and length > 0)
    ' "$contents_body" >/dev/null; then
      dispatch_fail 'preflight-failed' "$repository: immutable workflow content response violated the bounded file contract"
    fi

    workflow_source="$work_dir/workflow-source-${index}.yml"
    if ! workflow_content_sha256="$(python3 - "$contents_body" "$workflow_source" <<'PY'
import base64
import hashlib
import json
import pathlib
import re
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
encoded = payload['content']
if not re.fullmatch(r'[A-Za-z0-9+/=\r\n\t ]+', encoded):
    raise SystemExit('workflow content contains non-base64 characters')
try:
    decoded = base64.b64decode(''.join(encoded.split()), validate=True)
except Exception as exc:
    raise SystemExit(f'invalid workflow base64 content: {exc}')
if len(decoded) != payload['size']:
    raise SystemExit(f"workflow decoded size {len(decoded)} does not match declared size {payload['size']}")
try:
    text = decoded.decode('utf-8')
except UnicodeDecodeError as exc:
    raise SystemExit(f'workflow is not UTF-8: {exc}')
pathlib.Path(sys.argv[2]).write_text(text)
print('sha256:' + hashlib.sha256(decoded).hexdigest())
PY
)"; then
      dispatch_fail 'preflight-failed' "$repository: immutable workflow source failed strict decoding"
    fi

    if ! ruby - "$workflow_source" <<'RB'
require 'yaml'
path = ARGV.fetch(0)
doc = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
raise 'workflow root must be a mapping' unless doc.is_a?(Hash)
triggers = doc['on'] || doc[true]
raise 'workflow_dispatch trigger is missing' unless triggers.is_a?(Hash) && triggers.key?('workflow_dispatch')
dispatch = triggers['workflow_dispatch'] || {}
raise 'workflow_dispatch must be a mapping' unless dispatch.is_a?(Hash)
inputs = dispatch['inputs'] || {}
raise 'live_e2e workflow input is missing' unless inputs.is_a?(Hash) && inputs.key?('live_e2e')
jobs = doc['jobs']
raise 'workflow jobs must be a non-empty mapping' unless jobs.is_a?(Hash) && !jobs.empty?
runs = jobs.values.flat_map do |job|
  next [] unless job.is_a?(Hash)
  steps = job['steps']
  next [] unless steps.is_a?(Array)
  steps.filter_map { |step| step.is_a?(Hash) && step['run'].is_a?(String) ? step['run'] : nil }
end.join("\n")
required = [
  'OPTO_SYNC_REQUIRE_BROWSER=1',
  'npm run test:node',
  'npm run test:browser',
  'downstream-product.e2e.test.mjs'
]
missing = required.reject { |token| runs.include?(token) }
raise "executable workflow steps are missing markers: #{missing.join(', ')}" unless missing.empty?
RB
    then
      dispatch_fail 'preflight-failed' "$repository: immutable workflow source failed the structured conformance contract"
    fi

    jq -nc \
      --arg repository "$repository" \
      --arg workflow_path "$workflow_path" \
      --arg workflow_blob_sha "$workflow_blob_sha" \
      --arg workflow_content_sha256 "$workflow_content_sha256" \
      --arg expected_head_sha "$expected_head_sha" \
      --argjson workflow_id "$workflow_id" \
      '{
        testRepository: $repository,
        workflowId: $workflow_id,
        workflowPath: $workflow_path,
        workflowBlobSha: $workflow_blob_sha,
        workflowContentSha256: $workflow_content_sha256,
        expectedHeadSha: $expected_head_sha
      }' >> "$preflight_ndjson"
  done < <(jq -c '.targets[]' "$plan")
  [[ "$index" == "$target_count" ]] || dispatch_fail 'preflight-failed' 'preflight target count changed while reading the plan'
  refresh_collections

  local dispatch_body dispatch_response dispatch_code workflow_run_id run_url html_url expected_html_url
  local recheck_body recheck_code rechecked_head_sha
  while IFS= read -r target; do
    repository="$(jq -r '.testRepository' <<<"$target")"
    workflow_id="$(jq -r '.workflowId' <<<"$target")"
    workflow_metadata_path="$(jq -r '.workflowPath' <<<"$target")"
    workflow_blob_sha="$(jq -r '.workflowBlobSha' <<<"$target")"
    workflow_content_sha256="$(jq -r '.workflowContentSha256' <<<"$target")"
    expected_head_sha="$(jq -r '.expectedHeadSha' <<<"$target")"

    recheck_body="$work_dir/ref-recheck-${workflow_id}.json"
    if ! recheck_code="$(curl_request GET "$api_url/repos/$repository/commits/$workflow_ref" "$recheck_body")"; then
      dispatch_fail 'dispatch-failed' "$repository: pre-dispatch ref recheck transport or size failure"
    fi
    [[ "$recheck_code" == '200' ]] || dispatch_fail 'dispatch-failed' "$repository: pre-dispatch ref recheck returned HTTP $recheck_code"
    rechecked_head_sha="$(jq -r '.sha // empty' "$recheck_body")"
    [[ "$rechecked_head_sha" == "$expected_head_sha" ]] || \
      dispatch_fail 'dispatch-failed' "$repository: workflow ref moved after immutable preflight"

    dispatch_body="$(jq -nc --arg ref "$workflow_ref" '{ref: $ref, inputs: {live_e2e: true}}')"
    dispatch_response="$work_dir/dispatch-${workflow_id}.json"
    if ! dispatch_code="$(curl_request POST \
      "$api_url/repos/$repository/actions/workflows/$workflow_id/dispatches" \
      "$dispatch_response" "$dispatch_body")"; then
      dispatch_fail 'dispatch-failed' "$repository: workflow dispatch transport or size failure"
    fi
    [[ "$dispatch_code" == '200' ]] || \
      dispatch_fail 'dispatch-failed' "$repository: workflow dispatch returned HTTP $dispatch_code; API version $api_version requires a workflow-run response"
    workflow_run_id="$(jq -r '.workflow_run_id // empty' "$dispatch_response")"
    run_url="$(jq -r '.run_url // empty' "$dispatch_response")"
    html_url="$(jq -r '.html_url // empty' "$dispatch_response")"
    [[ "$workflow_run_id" =~ ^[1-9][0-9]*$ ]] || dispatch_fail 'dispatch-failed' "$repository: dispatch response has no positive workflow run id"
    [[ "$run_url" == "$api_url/repos/$repository/actions/runs/$workflow_run_id" ]] || \
      dispatch_fail 'dispatch-failed' "$repository: dispatch response run URL does not match the requested repository and run id"
    expected_html_url="$github_web_origin/$repository/actions/runs/$workflow_run_id"
    [[ "$html_url" == "$expected_html_url" ]] || \
      dispatch_fail 'dispatch-failed' "$repository: dispatch response HTML URL escaped the configured GitHub web origin"

    jq -nc \
      --arg repository "$repository" \
      --arg workflow_path "$workflow_metadata_path" \
      --arg workflow_ref "$workflow_ref" \
      --arg workflow_blob_sha "$workflow_blob_sha" \
      --arg workflow_content_sha256 "$workflow_content_sha256" \
      --arg expected_head_sha "$expected_head_sha" \
      --arg run_url "$run_url" \
      --arg html_url "$html_url" \
      --argjson workflow_id "$workflow_id" \
      --argjson workflow_run_id "$workflow_run_id" '
        {
          testRepository: $repository,
          workflowId: $workflow_id,
          workflowPath: $workflow_path,
          workflowRef: $workflow_ref,
          workflowBlobSha: $workflow_blob_sha,
          workflowContentSha256: $workflow_content_sha256,
          expectedHeadSha: $expected_head_sha,
          workflowRunId: $workflow_run_id,
          runUrl: $run_url,
          htmlUrl: $html_url,
          dispatchStatus: "accepted"
        }
      ' >> "$dispatches_ndjson"
    refresh_collections
  done < <(jq -c '.[]' "$preflight_json")

  local deadline all_completed run_record run_body run_code run_id run_status conclusion run_head_sha run_head_branch run_path
  local allowed_path allowed_refs_path created_at updated_at run_attempt
  deadline=$((SECONDS + wait_timeout))
  while true; do
    : > "$runs_ndjson"
    all_completed='true'
    while IFS= read -r run_record; do
      repository="$(jq -r '.testRepository' <<<"$run_record")"
      workflow_id="$(jq -r '.workflowId' <<<"$run_record")"
      run_id="$(jq -r '.workflowRunId' <<<"$run_record")"
      run_url="$(jq -r '.runUrl' <<<"$run_record")"
      expected_head_sha="$(jq -r '.expectedHeadSha' <<<"$run_record")"
      run_body="$work_dir/run-${run_id}.json"
      if ! run_code="$(curl_request GET "$run_url" "$run_body")"; then
        jq -nc --arg repository "$repository" --argjson workflow_run_id "$run_id" '{
          testRepository: $repository,
          workflowRunId: $workflow_run_id,
          runStatus: "lookup-failed",
          conclusion: null
        }' >> "$runs_ndjson"
        dispatch_fail 'poll-failed' "$repository: workflow run $run_id lookup transport or size failure"
      fi
      [[ "$run_code" == '200' ]] || {
        jq -nc --arg repository "$repository" --argjson workflow_run_id "$run_id" '{
          testRepository: $repository,
          workflowRunId: $workflow_run_id,
          runStatus: "lookup-failed",
          conclusion: null
        }' >> "$runs_ndjson"
        dispatch_fail 'poll-failed' "$repository: workflow run $run_id lookup returned HTTP $run_code"
      }
      allowed_path="$workflow_path@$workflow_ref"
      allowed_refs_path="$workflow_path@refs/heads/$workflow_ref"
      if ! jq --exit-status \
        --arg repository "$repository" \
        --arg workflow_ref "$workflow_ref" \
        --arg workflow_path "$workflow_path" \
        --arg allowed_path "$allowed_path" \
        --arg allowed_refs_path "$allowed_refs_path" \
        --arg expected_head_sha "$expected_head_sha" \
        --argjson workflow_id "$workflow_id" \
        --argjson run_id "$run_id" '
          .id == $run_id and
          .workflow_id == $workflow_id and
          .event == "workflow_dispatch" and
          .head_sha == $expected_head_sha and
          .head_branch == $workflow_ref and
          (.path == $allowed_path or .path == $allowed_refs_path) and
          .repository.full_name == $repository and
          (.run_attempt | type == "number" and floor == . and . >= 1) and
          (.created_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
          (.updated_at | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
          (.status | IN("requested", "waiting", "pending", "queued", "in_progress", "completed")) and
          (if .status == "completed" then
             (.conclusion | IN("success", "failure", "neutral", "cancelled", "skipped", "timed_out", "action_required", "stale", "startup_failure"))
           else .conclusion == null end)
        ' "$run_body" >/dev/null; then
        jq -nc \
          --arg repository "$repository" \
          --argjson workflow_run_id "$run_id" \
          --arg head_sha "$(jq -r '.head_sha // empty' "$run_body" 2>/dev/null || true)" \
          --arg head_branch "$(jq -r '.head_branch // empty' "$run_body" 2>/dev/null || true)" \
          --arg run_path "$(jq -r '.path // empty' "$run_body" 2>/dev/null || true)" '{
            testRepository: $repository,
            workflowRunId: $workflow_run_id,
            runStatus: "contract-violation",
            conclusion: null,
            headSha: $head_sha,
            headBranch: $head_branch,
            runPath: $run_path
          }' >> "$runs_ndjson"
        dispatch_fail 'poll-failed' "$repository: workflow run $run_id violated the immutable completion contract"
      fi
      run_status="$(jq -r '.status' "$run_body")"
      conclusion="$(jq -r '.conclusion // empty' "$run_body")"
      run_head_sha="$(jq -r '.head_sha' "$run_body")"
      run_head_branch="$(jq -r '.head_branch' "$run_body")"
      run_path="$(jq -r '.path' "$run_body")"
      run_attempt="$(jq -r '.run_attempt' "$run_body")"
      created_at="$(jq -r '.created_at' "$run_body")"
      updated_at="$(jq -r '.updated_at' "$run_body")"
      [[ "$run_status" == 'completed' ]] || all_completed='false'
      jq -nc \
        --arg repository "$repository" \
        --arg run_status "$run_status" \
        --arg conclusion "$conclusion" \
        --arg head_sha "$run_head_sha" \
        --arg head_branch "$run_head_branch" \
        --arg run_path "$run_path" \
        --arg created_at "$created_at" \
        --arg updated_at "$updated_at" \
        --argjson workflow_run_id "$run_id" \
        --argjson run_attempt "$run_attempt" '
          {
            testRepository: $repository,
            workflowRunId: $workflow_run_id,
            runStatus: $run_status,
            conclusion: (if $conclusion == "" then null else $conclusion end),
            runAttempt: $run_attempt,
            headSha: $head_sha,
            headBranch: $head_branch,
            runPath: $run_path,
            createdAt: $created_at,
            updatedAt: $updated_at
          }
        ' >> "$runs_ndjson"
    done < <(jq -c '.[]' "$dispatches_json")
    refresh_collections

    if [[ "$all_completed" == 'true' ]]; then
      break
    fi
    if (( SECONDS >= deadline )); then
      write_receipts "$dispatches_json" "$runs_json" "$receipts" 'timed-out' \
        "$plan_digest" "$api_url" "$api_version" "$target_count" \
        "consumer workflow completion timed out after ${wait_timeout}s"
      die "consumer workflow completion timed out after ${wait_timeout}s; receipts were written"
    fi
    sleep "$poll_interval"
  done

  local successful_count
  successful_count="$(jq '[.[] | select(.runStatus == "completed" and .conclusion == "success")] | length' "$runs_json")"
  if [[ "$successful_count" == "$target_count" ]]; then
    write_receipts "$dispatches_json" "$runs_json" "$receipts" 'completed' \
      "$plan_digest" "$api_url" "$api_version" "$target_count"
  else
    write_receipts "$dispatches_json" "$runs_json" "$receipts" 'failed' \
      "$plan_digest" "$api_url" "$api_version" "$target_count" \
      'one or more exact downstream workflow runs did not conclude success'
    local failed_repositories
    failed_repositories="$(jq -r '[.[] | select(.conclusion != "success") | .testRepository] | join(", ")' "$runs_json")"
    die "consumer workflows completed without universal success: $failed_repositories; receipts were written"
  fi

  trap - RETURN EXIT
  rm -rf "$work_dir"
}
