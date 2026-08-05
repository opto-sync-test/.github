# Organization agent policy

These instructions apply to automation and coding agents working in `opto-sync-test` repositories unless a repository defines stricter local policy.

## Durable engineering policy

- This repository defines public organization-wide defaults for `opto-sync-test`.
- Never commit credentials, private keys, access tokens, customer data, or private-repository inventories.
- Resolve Git conflicts semantically: inspect both sides, the merge base, nearby tests and contracts, and normally 3–10 relevant prior commits. Never blindly select all of `ours` or all of `theirs`.
- Prefer focused pull requests, explicit validation, non-destructive Git operations, and documented tradeoffs.
- Cross-repository integration uses versioned interfaces, APIs, SDKs, events, or explicitly owned replicated read models. Services do not reach into another service's database by default.
- `*-infra` repositories and `*-monorepo` application source remain separate. A `*-infra` repository must never appear as a Git submodule under `*-monorepo/apps`.
- Git submodules are reserved for explicitly coordinated editable source composition. Zed packages or immutable artifacts are preferred for package dependencies. Production deploys immutable artifacts or OCI digests, not source clones.

## Required workflow

1. Read repository-local instructions and relevant contracts before editing.
2. Inspect affected tests and 3–10 relevant commits when history is material.
3. Keep changes scoped and do not overwrite stronger local policy.
4. Run the most relevant formatter, linter, tests, and secret scan available.
5. Report exactly what changed, what was validated, and remaining uncertainty.
