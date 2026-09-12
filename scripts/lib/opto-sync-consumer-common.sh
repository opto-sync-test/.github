# shellcheck shell=bash
readonly PLAN_SCHEMA='opto-sync/consumer-execution-plan/v1'
readonly RECEIPT_SCHEMA='opto-sync/consumer-dispatch-receipts/v1'
readonly IMPACT_SCHEMA='opto-sync/consumer-impact/v1'
readonly ROOT_PACKAGE='opto-sync/opto-sync-clients'
readonly DECLARED_PACKAGE_INDEX_SCOPE='registry-wide-current-list-endpoint'
readonly DECLARED_PRIVATE_COVERAGE='graph-fetches-limited-to-caller-authorization'
readonly DECLARED_INVENTORY_CONSISTENCY='total-stable-pagination-without-registry-checkpoint'
readonly DEFAULT_WORKFLOW_FILE='opto-sync-wrapper-e2e.yml'
readonly DEFAULT_WORKFLOW_REF='main'
readonly DEFAULT_GITHUB_API_URL='https://api.github.com'
readonly DEFAULT_GITHUB_API_VERSION='2026-03-10'
readonly DEFAULT_POLL_INTERVAL_SECONDS='30'
readonly DEFAULT_WAIT_TIMEOUT_SECONDS='3600'
readonly DEFAULT_CONNECT_TIMEOUT_SECONDS='15'
readonly DEFAULT_REQUEST_TIMEOUT_SECONDS='120'
readonly DEFAULT_MAX_API_RESPONSE_BYTES='10485760'
readonly DEFAULT_MAX_WORKFLOW_SOURCE_BYTES='1048576'
readonly MAX_POLL_INTERVAL_SECONDS='300'
readonly MAX_WAIT_TIMEOUT_SECONDS='21600'

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
    [--github-api-version 2026-03-10] \
    [--poll-interval-seconds N] [--wait-timeout-seconds N] \
    [--max-api-response-bytes N]
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

require_bounded_positive_integer() {
  local value="$1" label="$2" maximum="$3"
  require_positive_integer "$value" "$label"
  (( value <= maximum )) || die "$label must not exceed $maximum"
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

normalize_github_api_url() {
  local value="$1"
  python3 - "$value" <<'PY'
import sys
import urllib.parse

value = sys.argv[1]
if not value or any(ord(ch) < 0x20 or ch.isspace() for ch in value):
    raise SystemExit('GitHub API URL contains whitespace or control characters')
try:
    parsed = urllib.parse.urlsplit(value)
    port = parsed.port
except ValueError as exc:
    raise SystemExit(f'invalid GitHub API URL: {exc}')
if parsed.scheme.lower() != 'https' or not parsed.hostname:
    raise SystemExit('GitHub API URL must be an absolute HTTPS URL')
if parsed.username is not None or parsed.password is not None:
    raise SystemExit('GitHub API URL must not contain userinfo')
if parsed.query or parsed.fragment:
    raise SystemExit('GitHub API URL must not contain a query or fragment')
try:
    parsed.hostname.encode('ascii')
except UnicodeEncodeError:
    raise SystemExit('GitHub API hostname must be ASCII')
host = parsed.hostname.lower()
path = parsed.path.rstrip('/')
if path not in {'', '/api/v3'}:
    raise SystemExit('GitHub API URL path must be empty or /api/v3')
port = 443 if port is None else port
host_text = f'[{host}]' if ':' in host else host
origin = f'https://{host_text}' + ('' if port == 443 else f':{port}')
api_root = origin + path
web_origin = 'https://github.com' if host == 'api.github.com' and port == 443 and path == '' else origin
print(api_root)
print(web_origin)
PY
}

validate_secret_header_value() {
  local value="$1" label="$2"
  [[ -n "$value" ]] || die "$label is empty"
  (( ${#value} <= 4096 )) || die "$label exceeds 4096 characters"
  [[ "$value" != *$'\r'* && "$value" != *$'\n'* ]] || die "$label contains a line break"
}

curl_request() {
  local method="$1" url="$2" output="$3" data="${4-}"
  local code size
  case "$method" in GET|POST) ;; *) printf 'unsupported HTTP method: %s\n' "$method" >&2; return 64 ;; esac
  case "$url" in "$GITHUB_API_URL"/*) ;; *) printf 'request escaped configured GitHub API root\n' >&2; return 64 ;; esac
  local -a args=(
    --silent --show-error
    --proto '=https' --tlsv1.2
    --max-redirs 0
    --connect-timeout "$CONNECT_TIMEOUT_SECONDS"
    --max-time "$REQUEST_TIMEOUT_SECONDS"
    --max-filesize "$MAX_API_RESPONSE_BYTES"
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
  if ! code="$("$CURL_BIN" "${args[@]}")"; then
    return 65
  fi
  [[ "$code" =~ ^[0-9]{3}$ ]] || { printf 'curl returned an invalid HTTP status\n' >&2; return 65; }
  [[ -f "$output" ]] || { printf 'curl did not create its response file\n' >&2; return 65; }
  size="$(wc -c < "$output" | tr -d ' ')"
  [[ "$size" =~ ^[0-9]+$ ]] || { printf 'could not measure API response\n' >&2; return 65; }
  (( size <= MAX_API_RESPONSE_BYTES )) || { printf 'API response exceeded configured byte limit\n' >&2; return 65; }
  printf '%s' "$code"
}

write_receipts() {
  local dispatches_path="$1" runs_path="$2" output="$3" overall_status="$4"
  local plan_digest="$5" api_url="$6" api_version="$7" expected_count="$8" reason="${9-}"
  local temporary
  temporary="$(mktemp "${output}.tmp.XXXXXX")"
  jq --sort-keys -n \
    --slurpfile dispatches "$dispatches_path" \
    --slurpfile runs "$runs_path" \
    --arg schema "$RECEIPT_SCHEMA" \
    --arg plan_digest "$plan_digest" \
    --arg api_url "$api_url" \
    --arg api_version "$api_version" \
    --arg status "$overall_status" \
    --arg reason "$reason" \
    --argjson expected_count "$expected_count" '
      ($runs[0] | map({key: .testRepository, value: .}) | from_entries) as $run_by_repo
      | ($dispatches[0]
          | map(. + ($run_by_repo[.testRepository] // {}))
          | sort_by(.testRepository)) as $entries
      | ($entries | map(select(.runStatus == "completed")) | length) as $completed
      | {
          schema: $schema,
          planDigest: $plan_digest,
          apiUrl: $api_url,
          apiVersion: $api_version,
          status: $status,
          targetCount: $expected_count,
          acceptedCount: ($entries | map(select(.dispatchStatus == "accepted")) | length),
          completedCount: $completed,
          successfulCount: ($entries | map(select(.runStatus == "completed" and .conclusion == "success")) | length),
          failedCount: ($entries | map(select(.runStatus == "completed" and .conclusion != "success")) | length),
          pendingCount: ($expected_count - $completed),
          dispatches: $entries
        }
        + (if $reason == "" then {} else {reason: $reason} end)
    ' > "$temporary"
  mv "$temporary" "$output"
}
