# shellcheck shell=bash
plan_command() {
  local report='' output='' min_targets='1' max_targets='50'
  local workflow_file="$DEFAULT_WORKFLOW_FILE" workflow_ref="$DEFAULT_WORKFLOW_REF"

  while (($#)); do
    case "$1" in
      --report) [[ $# -ge 2 ]] || die '--report requires a value'; report="$2"; shift 2 ;;
      --output) [[ $# -ge 2 ]] || die '--output requires a value'; output="$2"; shift 2 ;;
      --min-targets) [[ $# -ge 2 ]] || die '--min-targets requires a value'; min_targets="$2"; shift 2 ;;
      --max-targets) [[ $# -ge 2 ]] || die '--max-targets requires a value'; max_targets="$2"; shift 2 ;;
      --workflow-file) [[ $# -ge 2 ]] || die '--workflow-file requires a value'; workflow_file="$2"; shift 2 ;;
      --workflow-ref) [[ $# -ge 2 ]] || die '--workflow-ref requires a value'; workflow_ref="$2"; shift 2 ;;
      -h|--help) usage; return 0 ;;
      *) die "unsupported plan argument: $1" ;;
    esac
  done

  [[ -n "$report" && -f "$report" ]] || die '--report must name an existing JSON file'
  [[ -n "$output" ]] || die '--output is required'
  require_positive_integer "$min_targets" '--min-targets'
  require_positive_integer "$max_targets" '--max-targets'
  (( min_targets <= max_targets )) || die '--min-targets cannot exceed --max-targets'
  validate_workflow_file "$workflow_file"
  validate_ref "$workflow_ref"
  require_command jq

  mkdir -p "$(dirname "$output")"
  local temporary
  temporary="$(mktemp "${output}.tmp.XXXXXX")"
  trap 'rm -f "${temporary:-}"' RETURN

  jq --exit-status --sort-keys \
    --arg impact_schema "$IMPACT_SCHEMA" \
    --arg plan_schema "$PLAN_SCHEMA" \
    --arg root_package "$ROOT_PACKAGE" \
    --arg private_coverage "$DECLARED_PRIVATE_COVERAGE" \
    --arg workflow_file "$workflow_file" \
    --arg workflow_ref "$workflow_ref" \
    --argjson min_targets "$min_targets" \
    --argjson max_targets "$max_targets" '
      def coordinate:
        type == "string" and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$");
      def issue_id:
        type == "string" and test("^[A-Z][A-Z0-9]+-[1-9][0-9]*$");
      def classification:
        type == "string" and IN("exact-pin", "package-release", "adapted-concept", "candidate");
      def fail($message): error($message);

      . as $report
      | if $report.schema != $impact_schema then fail("unexpected impact schema") else . end
      | if $report.root != $root_package then fail("unexpected impact root coordinate") else . end
      | if ($report.inventory.inventoryDigest | type != "string" or
            (test("^sha256:[0-9a-f]{64}$") | not))
        then fail("invalid inventory digest") else . end
      | if $report.semantics.graphView != "declared" or
           $report.semantics.resolution != "unresolved-requirements" or
           $report.semantics.privateCoverage != $private_coverage
        then fail("consumer execution requires caller-scoped declared unresolved graph semantics") else . end
      | if ($report.consumers | type) != "array" then fail("impact consumers must be an array") else . end
      | if ($report.gaps | type) != "object" then fail("impact gaps must be an object") else . end
      | if (($report.gaps.graphOnly // []) | length) != 0
        then fail("graph-only consumers must be reconciled before execution") else . end
      | if (($report.gaps.unclassified // []) | length) != 0
        then fail("unclassified consumers must be reconciled before execution") else . end
      | if (($report.inventory.missingGraphCount // 0) != 0)
        then fail("missing declared graphs must be reconciled before execution") else . end
      | [
          $report.consumers[]
          | select(.coverageStatus == "graph-confirmed")
          | if (.repository | coordinate) | not then fail("invalid graph-confirmed consumer coordinate") else . end
          | if (.testRepository | coordinate) | not then fail("graph-confirmed consumer lacks a valid test repository") else . end
          | if (.minimumDepth | type) != "number" or (.minimumDepth | floor) != .minimumDepth or .minimumDepth < 1
            then fail("graph-confirmed consumer has an invalid minimum depth") else . end
          | if (.adoptionClassification | classification) | not
            then fail("graph-confirmed consumer has an invalid adoption classification") else . end
          | if (.linearIssue | issue_id) | not
            then fail("graph-confirmed consumer has an invalid Linear issue") else . end
          | {
              repository,
              testRepository,
              minimumDepth,
              adoptionClassification,
              linearIssue
            }
        ] as $confirmed
      | if ($confirmed | length) != ($confirmed | map(.repository) | unique | length)
        then fail("graph-confirmed consumer repositories must be unique") else . end
      | ($confirmed
          | sort_by(.testRepository, .repository)
          | group_by(.testRepository)
          | map({
              testRepository: .[0].testRepository,
              consumers: (map({
                repository,
                minimumDepth,
                adoptionClassification,
                linearIssue
              }) | sort_by(.repository))
            })
          | sort_by(.testRepository)
        ) as $targets
      | if ($targets | length) < $min_targets
        then fail("execution plan has fewer targets than required") else . end
      | if ($targets | length) > $max_targets
        then fail("execution plan exceeds the target safety limit") else . end
      | {
          schema: $plan_schema,
          source: {
            root: $report.root,
            inventoryDigest: $report.inventory.inventoryDigest,
            graphView: $report.semantics.graphView,
            resolution: $report.semantics.resolution,
            privateCoverage: $report.semantics.privateCoverage
          },
          workflow: {
            file: $workflow_file,
            path: (".github/workflows/" + $workflow_file),
            ref: $workflow_ref,
            inputs: {live_e2e: true}
          },
          completion: {
            required: true,
            successfulConclusions: ["success"]
          },
          consumerCount: ($confirmed | length),
          targetCount: ($targets | length),
          targets: $targets
        }
    ' "$report" > "$temporary" || die 'impact report failed execution-plan validation'

  mv "$temporary" "$output"
  trap - RETURN
}
