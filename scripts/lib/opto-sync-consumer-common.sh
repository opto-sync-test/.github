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
readonly DEFAULT_CURL_CONNECT_TIMEOUT_SECONDS='10'
readonly DEFAULT_CURL_MAX_TIME_SECONDS='60'
readonly DEFAULT_CURL_MAX_RESPONSE_BYTES='4194304'
readonly MAX_DISPATCH_TOKEN_LENGTH='4096'

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

validate_github_api_url() {
  local value="${1%/}" trusted="${OPTO_SYNC_TRUSTED_GITHUB_API_URL:-}"
  [[ "$value" =~ ^https://[^/?#]+(/api/v3)?$ ]] || \
    die '--github-api-url must be an HTTPS GitHub API root'
  [[ "$value" == "$DEFAULT_GITHUB_API_URL" ]] && return 0
  trusted="${trusted%/}"
  [[ -n "$trusted" && "$value" == "$trusted" ]] || \
    die 'non-default GitHub API roots require an exact OPTO_SYNC_TRUSTED_GITHUB_API_URL allowlist'
}

github_web_url_for_api() {
  local api_url="${1%/}" web_url
  if [[ "$api_url" == "$DEFAULT_GITHUB_API_URL" ]]; then
    printf '%s\n' 'https://github.com'
    return 0
  fi
  if [[ "$api_url" == */api/v3 ]]; then
    printf '%s\n' "${api_url%/api/v3}"
    return 0
  fi
  web_url="${OPTO_SYNC_TRUSTED_GITHUB_WEB_URL:-}"
  web_url="${web_url%/}"
  [[ "$web_url" =~ ^https://[^/?#]+$ ]] || \
    die 'a nonstandard API host requires OPTO_SYNC_TRUSTED_GITHUB_WEB_URL'
  printf '%s\n' "$web_url"
}

validate_dispatch_token() {
  local value="$1"
  [[ -n "$value" ]] || die 'dispatch token is empty'
  (( ${#value} <= MAX_DISPATCH_TOKEN_LENGTH )) || die 'dispatch token exceeds the safety limit'
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || \
    die 'dispatch token contains unsupported characters'
}

refuse_symlink_output() {
  local output="$1"
  if test -h "$output"; then
    die "refusing to replace symlink output: $output"
  fi
}

curl_request() {
  local method="$1" url="$2" output="$3" data="${4-}"
  local -a args=(
    --disable
    --silent --show-error
    --globoff
    --proto '=https'
    --tlsv1.2
    --connect-timeout "$DEFAULT_CURL_CONNECT_TIMEOUT_SECONDS"
    --max-time "$DEFAULT_CURL_MAX_TIME_SECONDS"
    --max-filesize "$DEFAULT_CURL_MAX_RESPONSE_BYTES"
    --request "$method"
    --output "$output"
    --write-out '%{http_code}'
    --header 'Accept: application/vnd.github+json'
    --header "Authorization: Bearer $DISPATCH_TOKEN"
    --header "X-GitHub-Api-Version: $GITHUB_API_VERSION"
    --header 'User-Agent: opto-sync-consumer-dispatch/1'
  )
  if [[ -n "$data" ]]; then
    args+=(--header 'Content-Type: application/json' --data "$data")
  fi
  args+=(--url "$url")
  "$CURL_BIN" "${args[@]}"
}

write_receipts() {
  local dispatches_path="$1" runs_path="$2" output="$3" overall_status="$4"
  local plan_digest="$5" api_url="$6" api_version="$7"
  local reason="${8-}" temporary
  refuse_symlink_output "$output"
  mkdir -p "$(dirname "$output")"
  temporary="$(mktemp "${output}.tmp.XXXXXX")"
  chmod 600 "$temporary"
  if ! jq --sort-keys -n \
    --slurpfile dispatches "$dispatches_path" \
    --slurpfile runs "$runs_path" \
    --arg schema "$RECEIPT_SCHEMA" \
    --arg plan_digest "$plan_digest" \
    --arg api_url "$api_url" \
    --arg api_version "$api_version" \
    --arg status "$overall_status" \
    --arg reason "$reason" '
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
          dispatchFailedCount: ($entries | map(select(.dispatchStatus == "preflight-failed" or .dispatchStatus == "failed" or .dispatchStatus == "response-invalid")) | length),
          notDispatchedCount: ($entries | map(select(.dispatchStatus == "pending")) | length),
          completedCount: ($entries | map(select(.runStatus == "completed")) | length),
          successfulCount: ($entries | map(select(.runStatus == "completed" and .conclusion == "success")) | length),
          failedCount: ($entries | map(select(.runStatus == "completed" and .conclusion != "success")) | length),
          pendingCount: ($entries | map(select(.runStatus != "completed")) | length),
          dispatches: $entries
        }
      | if $reason == "" then . else . + {reason: $reason} end
    ' > "$temporary"; then
    rm -f "$temporary"
    die "could not write dispatch receipts: $output"
  fi
  mv -f -- "$temporary" "$output"
  chmod 600 "$output"
}
