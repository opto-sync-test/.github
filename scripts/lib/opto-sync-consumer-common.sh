# shellcheck shell=bash
readonly PLAN_SCHEMA='opto-sync/consumer-execution-plan/v1'
readonly RECEIPT_SCHEMA='opto-sync/consumer-dispatch-receipts/v1'
readonly IMPACT_SCHEMA='opto-sync/consumer-impact/v1'
readonly ROOT_PACKAGE='opto-sync/opto-sync-clients'
readonly DECLARED_PRIVATE_COVERAGE='limited-to-caller-authorized-visible-inventory'
readonly DEFAULT_WORKFLOW_FILE='opto-sync-wrapper-e2e.yml'
readonly DEFAULT_WORKFLOW_REF='main'
readonly DEFAULT_GITHUB_API_URL='https://api.github.com'
readonly DEFAULT_GITHUB_API_VERSION='2026-03-10'
readonly DEFAULT_POLL_INTERVAL_SECONDS='30'
readonly DEFAULT_WAIT_TIMEOUT_SECONDS='3600'

usage() {
  cat >&2 <<'USAGE'
Usage:
  opto-sync-consumer-dispatch.sh plan \
    --report PATH --output PATH \
    [--min-targets N] [--max-targets N] \
    [--workflow-file NAME] [--workflow-ref REF]

  opto-sync-consumer-dispatch.sh dispatch \
    --plan PATH --receipts PATH \
    [--token-env NAME] [--github-api-url URL] \
    [--github-api-version YYYY-MM-DD] \
    [--poll-interval-seconds N] [--wait-timeout-seconds N]
USAGE
}

die() {
  printf 'opto-sync-consumer-dispatch: %s\n' "$*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command is unavailable: $1"
}

require_positive_integer() {
  local value="$1" label="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$label must be a positive integer"
}

sha256_file() {
  local path="$1" digest
  if command -v sha256sum >/dev/null 2>&1; then
    digest="$(sha256sum "$path" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    digest="$(shasum -a 256 "$path" | awk '{print $1}')"
  else
    die 'sha256sum or shasum is required'
  fi
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || die "could not compute SHA-256 for $path"
  printf 'sha256:%s\n' "$digest"
}

validate_workflow_file() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9_.-]+\.ya?ml$ ]] || \
    die '--workflow-file must be a workflow filename ending in .yml or .yaml'
}

validate_ref() {
  local value="$1"
  [[ "$value" =~ ^[A-Za-z0-9._/-]+$ ]] || die '--workflow-ref contains unsupported characters'
  [[ "$value" != /* && "$value" != *'..'* && "$value" != */ ]] || \
    die '--workflow-ref must be a normalized branch or tag name'
}


curl_request() {
  local method="$1" url="$2" output="$3" data="${4-}"
  local -a args=(
    --silent --show-error --location
    --request "$method"
    --output "$output"
    --write-out '%{http_code}'
    --header 'Accept: application/vnd.github+json'
    --header "Authorization: Bearer $DISPATCH_TOKEN"
    --header "X-GitHub-Api-Version: $GITHUB_API_VERSION"
  )
  if [[ -n "$data" ]]; then
    args+=(--header 'Content-Type: application/json' --data "$data")
  fi
  args+=("$url")
  "$CURL_BIN" "${args[@]}"
}

write_receipts() {
  local dispatches_path="$1" runs_path="$2" output="$3" overall_status="$4"
  local plan_digest="$5" api_url="$6" api_version="$7"
  local temporary
  temporary="$(mktemp "${output}.tmp.XXXXXX")"
  jq --sort-keys -n \
    --slurpfile dispatches "$dispatches_path" \
    --slurpfile runs "$runs_path" \
    --arg schema "$RECEIPT_SCHEMA" \
    --arg plan_digest "$plan_digest" \
    --arg api_url "$api_url" \
    --arg api_version "$api_version" \
    --arg status "$overall_status" '
      ($runs[0] | map({key: .testRepository, value: .}) | from_entries) as $run_by_repo
      | ($dispatches[0]
          | map(. + ($run_by_repo[.testRepository] // {}))
          | sort_by(.testRepository)) as $entries
      | {
          schema: $schema,
          planDigest: $plan_digest,
          apiUrl: $api_url,
          apiVersion: $api_version,
          status: $status,
          targetCount: ($entries | length),
          acceptedCount: ($entries | map(select(.dispatchStatus == "accepted")) | length),
          completedCount: ($entries | map(select(.runStatus == "completed")) | length),
          successfulCount: ($entries | map(select(.runStatus == "completed" and .conclusion == "success")) | length),
          failedCount: ($entries | map(select(.runStatus == "completed" and .conclusion != "success")) | length),
          pendingCount: ($entries | map(select(.runStatus != "completed")) | length),
          dispatches: $entries
        }
    ' > "$temporary"
  mv "$temporary" "$output"
}
