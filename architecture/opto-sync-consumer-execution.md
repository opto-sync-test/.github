# Opto-Sync graph-derived consumer execution

The test organization turns the Zed declared-dependency census from
`opto-sync/opto-sync-e2e` into a bounded, independently verified downstream
execution plan.

## Evidence boundary

The current Zed package-list endpoint is a registry-wide index. Authorization
is applied when each package version's declared graph is fetched. The canary
therefore reports:

- a registry-wide package index;
- caller-authorized graph fetches;
- declared, unresolved requirements rather than a resolved lock graph;
- a live census whose pagination total is checked for stability, but which has
  no registry generation/checkpoint and is not an atomic snapshot.

The plan refuses older reports that describe the inventory as globally private
or caller-scoped, allow redirects, omit registry identity, use a latest-only
version policy, or contain incomplete package-index pagination.

## Two-phase downstream execution

Before any workflow is dispatched, every target must pass all of these checks:

1. The execution plan is deterministic and contains no graph-only,
   unclassified, or missing-graph gaps.
2. The target repository and consumer coordinates are normalized and bounded.
3. The named workflow is active and resolves to the required path.
4. The configured branch resolves to a full immutable commit SHA.
5. The workflow file is fetched at that SHA, size-bounded, strictly decoded,
   fingerprinted, parsed as YAML, and checked for executable Opto-Sync node,
   browser, and downstream-product conformance steps.

Only after every target passes preflight does dispatch begin. Immediately before
an individual dispatch, the branch is resolved again; movement aborts the
remaining fan-out. The workflow ID is used for dispatch. The returned run URL
and web URL must remain on the configured GitHub origins. Each run must then
match the preflight commit SHA, branch, workflow ID, workflow path, repository,
and event before its conclusion is accepted.

GitHub's dispatch API still accepts a branch or tag ref rather than an immutable
commit ref. The second ref lookup narrows that race window, and the exact
returned-run check detects any remaining movement; it cannot prevent execution
of a moved ref in the final request/queue interval. This residual limitation is
recorded rather than hidden.

## Credential and transport controls

- Zed credentials are scoped only to the graph-enumeration step and are bound
  to an explicit registry origin by the pinned harness.
- The cross-repository dispatch credential is scoped only to the credential
  probe and dispatch steps.
- HTTP redirects are never followed while authorization headers are present.
- GitHub API roots reject userinfo, query strings, fragments, non-HTTPS schemes,
  and paths other than the GitHub Enterprise `/api/v3` form.
- API bodies, workflow source, connect time, request time, poll interval, total
  wait time, target count, coordinates, and token header values are bounded.
- Response bodies and authorization values are never copied into durable
  receipts or logs.

Prefer a narrowly installed GitHub App token for downstream dispatch. Limit its
repository installation to the test repositories and grant only the Actions
permission needed to dispatch/read runs plus metadata read access. Do not use a
broad personal access token for routine canaries.

## Durable outcomes

Receipts are written for success and for preflight, dispatch, polling, timeout,
and downstream-test failures. Accepted dispatch is never treated as completion.
A successful canary requires every selected exact run to complete with the
`success` conclusion.

The workflow remains draft-only until these repository settings are configured
and an authorized live run is retained:

- `OPTO_SYNC_E2E_GRAPH_HARNESS_SHA`: reviewed full 40-character harness commit;
- `ZED_REGISTRY_URL` and, where needed, `ZED_REGISTRY_TOKEN` plus
  `ZED_REGISTRY_TOKEN_ORIGIN`;
- `OPTO_SYNC_TEST_DISPATCH_TOKEN`: narrowly scoped GitHub App installation token;
- optional fail-closed variables `OPTO_SYNC_REQUIRE_LIVE_ZED_GRAPH` and
  `OPTO_SYNC_REQUIRE_CONSUMER_DISPATCH`.
