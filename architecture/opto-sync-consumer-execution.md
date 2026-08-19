# Graph-derived Opto-Sync consumer execution

The Opto-Sync dependency census is useful only when discovered consumers are
connected to executable product tests. This repository owns the independent
test-organization policy that turns the pinned Zed declared-graph report into a
bounded, auditable downstream execution plan.

## Semantic boundary

The source report is a caller-authorized census of **declared, unresolved** Zed
requirements. It is not a resolved lock graph and does not claim visibility into
packages the configured registry credentials cannot see.

The execution planner therefore requires all of the following before it selects
any target:

- graph view `declared` and resolution `unresolved-requirements`;
- caller-scoped private coverage;
- no graph-only or unclassified consumers;
- no missing declared graphs;
- at least one graph-confirmed consumer with a curated E2E repository.

Curated-only entries remain visible rollout evidence but are not dispatched as
though the graph had confirmed them.

## Execution contract

`scripts/opto-sync-consumer-dispatch.sh` produces a deterministic plan grouped
by unique `testRepository`. Every selected repository must expose the active
workflow `.github/workflows/opto-sync-wrapper-e2e.yml` on `main`, with the
Boolean `live_e2e` input.

The dispatcher preflights every target before it dispatches any target. It then
uses GitHub REST API version `2026-03-10`, which returns the exact workflow-run
ID for each accepted dispatch. The controller polls those exact run IDs and
fails unless every run completes with conclusion `success`.

A dispatch acceptance is not treated as test completion. Receipts include the
workflow ID, workflow-run ID, API and HTML run URLs, status, conclusion, attempt,
head SHA, and timestamps for each selected repository.

## Configuration

Repository variables:

- `OPTO_SYNC_E2E_GRAPH_HARNESS_SHA`: reviewed lowercase 40-character commit SHA
  from `opto-sync/opto-sync-e2e`;
- `ZED_REGISTRY_URL`: HTTPS Zed registry API root;
- `OPTO_SYNC_REQUIRE_LIVE_ZED_GRAPH=true`: make missing live graph inputs fatal;
- `OPTO_SYNC_REQUIRE_CONSUMER_DISPATCH=true`: make missing dispatch credentials
  fatal.

Repository secrets:

- `ZED_REGISTRY_TOKEN`: optional bearer token defining the visible Zed inventory;
- `OPTO_SYNC_TEST_DISPATCH_TOKEN`: preferably a GitHub App installation token,
  or a fine-grained token, with Actions read/write access to each downstream E2E
  repository selected by the graph.

The dispatch token is passed only as a masked environment value and is never
written to the plan, logs, artifacts, or receipts.

## Safety limits

- one to fifty unique E2E targets per run;
- full fleet preflight before the first dispatch;
- exact standardized workflow filename and `main` ref;
- no automatic retry of a dispatch POST, avoiding duplicate runs after an
  ambiguous network response;
- sixty-minute downstream completion deadline and thirty-second polling;
- pull-request runs exercise deterministic fixtures only; scheduled or explicit
  dispatches perform live registry enumeration and downstream execution.
