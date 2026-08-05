# Repository boundary: infrastructure stays separate

**Policy ID:** `repo-boundary/infra-not-app-submodule/v1`  
**Status:** Permanent organization architecture rule

- A repository named `*-infra` is a standalone infrastructure and deployment codebase.
- A `*-infra` repository **must not** be added to any `*-monorepo` as a Git submodule, including anywhere under `*-monorepo/apps/`.
- Application/source code and infrastructure code must remain in separate repositories with independent history, ownership, release, and deployment lifecycles.
- A monorepo may integrate with infrastructure only through documented configuration, versioned contracts, CI/CD inputs, published artifacts, or deployment APIs. It must not vendor, nest, or mount the `*-infra` repository.
- Any existing `*-monorepo/apps/...` submodule whose remote points to a `*-infra` repository is non-conforming and should be removed.

Repository scaffolding, migration tooling, and automated agents must preserve this boundary unless the policy is explicitly revised.