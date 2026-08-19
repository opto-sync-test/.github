# shellcheck shell=bash
dispatch_command() {
  local plan='' receipts='' token_env='OPTO_SYNC_TEST_DISPATCH_TOKEN'
  local api_url="${GITHUB_API_URL:-$DEFAULT_GITHUB_API_URL}"
  local api_version="${GITHUB_API_VERSION:-$DEFAULT_GITHUB_API_VERSION}"
  local poll_interval="$DEFAULT_POLL_INTERVAL_SECONDS"
  local wait_timeout="$DEFAULT_WAIT_TIMEOUT_SECONDS"

  while (($#)); do
    case "$1" in
      --plan) [[ $# -ge 2 ]] || die '--plan requires a value'; plan="$2"; shift 2 ;;
      --receipts) [[ $# -ge 2 ]] || die '--receipts requires a value'; receipts="$2"; shift 2 ;;
      --token-env) [[ $# -ge 2 ]] || die '--token-env requires a value'; token_env="$2"; shift 2 ;;
      --github-api-url) [[ $# -ge 2 ]] || die '--github-api-url requires a value'; api_url="$2"; shift 2 ;;
      --github-api-version) [[ $# -ge 2 ]] || die '--github-api-version requires a value'; api_version="$2"; shift 2 ;;
      --poll-interval-seconds) [[ $# -ge 2 ]] || die '--poll-interval-seconds requires a value'; poll_interval="$2"; shift 2 ;;
      --wait-timeout-seconds) [[ $# -ge 2 ]] || die '--wait-timeout-seconds requires a value'; wait_timeout="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "unsupported dispatch argument: $1" ;;
    esac
  done

  [[ -n "$plan" && -f "$plan" ]] || die '--plan must name an existing JSON file'
  [[ -n "$receipts" ]] || die '--receipts is required'
  [[ "$token_env" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die '--token-env must be a valid environment variable name'
  [[ "$api_url" =~ ^https://[^/?#]+(/api/v3)?$ ]] || die '--github-api-url must be an HTTPS GitHub API root'
  [[ "$api_version" =~ ^20[0-9]{2}-[01][0-9]-[0-3][0-9]$ ]] || die '--github-api-version must use YYYY-MM-DD'
  require_positive_integer "$poll_interval" '--poll-interval-seconds'
  require_positive_integer "$wait_timeout" '--wait-timeout-seconds'
  api_url="${api_url%/}"
  require_command jq

  CURL_BIN="${CURL_BIN:-curl}"
  command -v "$CURL_BIN" >/dev/null 2>&1 || [[ -x "$CURL_BIN" ]] || die "curl implementation is unavailable: $CURL_BIN"
  DISPATCH_TOKEN="${!token_env-}"
  [[ -n "$DISPATCH_TOKEN" ]] || die "dispatch token environment variable is empty: $token_env"
  GITHUB_API_VERSION="$api_version"

  jq --exit-status \
    --arg schema "$PLAN_SCHEMA" \
    --arg root_package "$ROOT_PACKAGE" \
    --arg private_coverage "$DECLARED_PRIVATE_COVERAGE" \
    --arg workflow_file "$DEFAULT_WORKFLOW_FILE" \
    --arg workflow_ref "$DEFAULT_WORKFLOW_REF" '
      .schema == $schema and
      .source.root == $root_package and
      .source.graphView == "declared" and
      .source.resolution == "unresolved-requirements" and
      .source.privateCoverage == $private_coverage and
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
      (all(.targets[];
        (.testRepository | type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")) and
        (.consumers | type == "array" and length >= 1)
      ))
    ' "$plan" >/dev/null || die 'execution plan failed dispatch validation'

  mkdir -p "$(dirname "$receipts")"
  local work_dir plan_digest workflow_file workflow_ref target_count
  local preflight_ndjson preflight_json dispatches_ndjson dispatches_json runs_ndjson runs_json
  work_dir="$(mktemp -d)"
  trap 'rm -rf "${work_dir:-}"' RETURN
  preflight_ndjson="$work_dir/preflight.ndjson"
  preflight_json="$work_dir/preflight.json"
  dispatches_ndjson="$work_dir/dispatches.ndjson"
  dispatches_json="$work_dir/dispatches.json"
  runs_ndjson="$work_dir/runs.ndjson"
  runs_json="$work_dir/runs.json"
  : > "$preflight_ndjson"
  : > "$dispatches_ndjson"
  plan_digest="$(sha256_file "$plan")"
  workflow_file="$(jq -r '.workflow.file' "$plan")"
  workflow_ref="$(jq -r '.workflow.ref' "$plan")"
  target_count="$(jq -r '.targetCount' "$plan")"

  # Preflight every target before dispatching any workflow. This prevents a
  # stale or missing workflow in one repository from causing an avoidable
  # partially dispatched fleet.
  local index=0 target repository metadata_body metadata_code workflow_state workflow_path workflow_id
  while IFS= read -r target; do
    index=$((index + 1))
    repository="$(jq -r '.testRepository' <<<"$target")"
    metadata_body="$work_dir/workflow-${index}.json"
    metadata_code="$(curl_request GET \
      "$api_url/repos/$repository/actions/workflows/$workflow_file" \
      "$metadata_body")"
    [[ "$metadata_code" == '200' ]] || \
      die "$repository: workflow lookup returned HTTP $metadata_code"
    workflow_state="$(jq -r '.state // empty' "$metadata_body")"
    workflow_path="$(jq -r '.path // empty' "$metadata_body")"
    workflow_id="$(jq -r '.id // empty' "$metadata_body")"
    [[ "$workflow_state" == 'active' ]] || die "$repository: target workflow is not active"
    [[ "$workflow_path" == ".github/workflows/$workflow_file" ]] || \
      die "$repository: target workflow path does not match the execution contract"
    [[ "$workflow_id" =~ ^[1-9][0-9]*$ ]] || die "$repository: target workflow has no positive numeric id"
    jq -nc \
      --arg repository "$repository" \
      --arg workflow_path "$workflow_path" \
      --argjson workflow_id "$workflow_id" \
      '{testRepository: $repository, workflowId: $workflow_id, workflowPath: $workflow_path}' \
      >> "$preflight_ndjson"
  done < <(jq -c '.targets[]' "$plan")
  [[ "$index" == "$target_count" ]] || die 'preflight target count changed while reading the plan'
  jq -s --sort-keys 'sort_by(.testRepository)' "$preflight_ndjson" > "$preflight_json"

  local dispatch_body dispatch_response dispatch_code workflow_run_id run_url html_url
  while IFS= read -r target; do
    repository="$(jq -r '.testRepository' <<<"$target")"
    workflow_id="$(jq -r '.workflowId' <<<"$target")"
    workflow_path="$(jq -r '.workflowPath' <<<"$target")"
    dispatch_body="$(jq -nc --arg ref "$workflow_ref" '{ref: $ref, inputs: {live_e2e: true}}')"
    dispatch_response="$work_dir/dispatch-${workflow_id}.json"
    dispatch_code="$(curl_request POST \
      "$api_url/repos/$repository/actions/workflows/$workflow_file/dispatches" \
      "$dispatch_response" "$dispatch_body")"
    [[ "$dispatch_code" == '200' ]] || \
      die "$repository: workflow dispatch returned HTTP $dispatch_code; API version $api_version requires a workflow-run response"
    workflow_run_id="$(jq -r '.workflow_run_id // empty' "$dispatch_response")"
    run_url="$(jq -r '.run_url // empty' "$dispatch_response")"
    html_url="$(jq -r '.html_url // empty' "$dispatch_response")"
    [[ "$workflow_run_id" =~ ^[1-9][0-9]*$ ]] || die "$repository: dispatch response has no positive workflow run id"
    [[ "$run_url" == "$api_url/repos/$repository/actions/runs/$workflow_run_id" ]] || \
      die "$repository: dispatch response run URL does not match the requested repository and run id"
    [[ "$html_url" =~ ^https://[^[:space:]]+/actions/runs/$workflow_run_id$ ]] || \
      die "$repository: dispatch response has an invalid HTML run URL"
    jq -nc \
      --arg repository "$repository" \
      --arg workflow_path "$workflow_path" \
      --arg workflow_ref "$workflow_ref" \
      --arg run_url "$run_url" \
      --arg html_url "$html_url" \
      --argjson workflow_id "$workflow_id" \
      --argjson workflow_run_id "$workflow_run_id" '
        {
          testRepository: $repository,
          workflowId: $workflow_id,
          workflowPath: $workflow_path,
          workflowRef: $workflow_ref,
          workflowRunId: $workflow_run_id,
          runUrl: $run_url,
          htmlUrl: $html_url,
          dispatchStatus: "accepted"
        }
      ' >> "$dispatches_ndjson"
  done < <(jq -c '.[]' "$preflight_json")
  jq -s --sort-keys 'sort_by(.testRepository)' "$dispatches_ndjson" > "$dispatches_json"

  local deadline all_completed run_record run_body run_code run_id run_status conclusion
  deadline=$((SECONDS + wait_timeout))
  while true; do
    : > "$runs_ndjson"
    all_completed='true'
    while IFS= read -r run_record; do
      repository="$(jq -r '.testRepository' <<<"$run_record")"
      workflow_id="$(jq -r '.workflowId' <<<"$run_record")"
      run_id="$(jq -r '.workflowRunId' <<<"$run_record")"
      run_url="$(jq -r '.runUrl' <<<"$run_record")"
      run_body="$work_dir/run-${run_id}.json"
      run_code="$(curl_request GET "$run_url" "$run_body")"
      [[ "$run_code" == '200' ]] || die "$repository: workflow run $run_id lookup returned HTTP $run_code"
      jq --exit-status \
        --arg repository "$repository" \
        --argjson workflow_id "$workflow_id" \
        --argjson run_id "$run_id" '
          .id == $run_id and
          .workflow_id == $workflow_id and
          .event == "workflow_dispatch" and
          (.status | type == "string" and length > 0) and
          ((.repository.full_name // $repository) == $repository) and
          (if .status == "completed" then (.conclusion | type == "string" and length > 0) else true end)
        ' "$run_body" >/dev/null || die "$repository: workflow run $run_id violated the completion contract"
      run_status="$(jq -r '.status' "$run_body")"
      conclusion="$(jq -r '.conclusion // empty' "$run_body")"
      [[ "$run_status" == 'completed' ]] || all_completed='false'
      jq -nc \
        --arg repository "$repository" \
        --arg run_status "$run_status" \
        --arg conclusion "$conclusion" \
        --arg head_sha "$(jq -r '.head_sha // empty' "$run_body")" \
        --arg created_at "$(jq -r '.created_at // empty' "$run_body")" \
        --arg updated_at "$(jq -r '.updated_at // empty' "$run_body")" \
        --argjson workflow_run_id "$run_id" \
        --argjson run_attempt "$(jq -r '.run_attempt // 1' "$run_body")" '
          {
            testRepository: $repository,
            workflowRunId: $workflow_run_id,
            runStatus: $run_status,
            conclusion: (if $conclusion == "" then null else $conclusion end),
            runAttempt: $run_attempt,
            headSha: (if $head_sha == "" then null else $head_sha end),
            createdAt: (if $created_at == "" then null else $created_at end),
            updatedAt: (if $updated_at == "" then null else $updated_at end)
          }
        ' >> "$runs_ndjson"
    done < <(jq -c '.[]' "$dispatches_json")
    jq -s --sort-keys 'sort_by(.testRepository)' "$runs_ndjson" > "$runs_json"

    if [[ "$all_completed" == 'true' ]]; then
      break
    fi
    if (( SECONDS >= deadline )); then
      write_receipts "$dispatches_json" "$runs_json" "$receipts" 'timed-out' \
        "$plan_digest" "$api_url" "$api_version"
      die "consumer workflow completion timed out after ${wait_timeout}s; receipts were written"
    fi
    sleep "$poll_interval"
  done

  local successful_count
  successful_count="$(jq '[.[] | select(.runStatus == "completed" and .conclusion == "success")] | length' "$runs_json")"
  if [[ "$successful_count" == "$target_count" ]]; then
    write_receipts "$dispatches_json" "$runs_json" "$receipts" 'completed' \
      "$plan_digest" "$api_url" "$api_version"
  else
    write_receipts "$dispatches_json" "$runs_json" "$receipts" 'failed' \
      "$plan_digest" "$api_url" "$api_version"
    local failed_repositories
    failed_repositories="$(jq -r '[.[] | select(.conclusion != "success") | .testRepository] | join(", ")' "$runs_json")"
    die "consumer workflows completed without universal success: $failed_repositories"
  fi

  trap - RETURN
  rm -rf "$work_dir"
}
