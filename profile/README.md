# opto-sync-test

Independent acceptance organization for **opto-sync**.

IndexedDB/SQLite/PostgreSQL/Supabase sync, conflicts, background execution, validators, and Rust/C conformance.

The fleet spans browser, chaos, database, Flutter-emulator, interoperability, protocol, SDK-consumer, and security acceptance profiles. Generated pull-request workflows use least privilege, immutable action pins, and no persisted checkout credentials; integration workflows requiring private cross-organization access remain explicitly gated.

## Polyglot full-stack acceptance

The active cross-platform matrix now includes:

- [SAFE Stack / Fable / C# and F#](https://github.com/opto-sync-test/safe-fable-dotnet-e2e)
- [Kotlin Multiplatform](https://github.com/opto-sync-test/kotlin-multiplatform-e2e)
- [Vaadin / Java](https://github.com/opto-sync-test/vaadin-java-e2e)
- [Leptos + Dioxus / Rust](https://github.com/opto-sync-test/leptos-dioxus-rust-e2e)
- [Gleam / BEAM + WebAssembly](https://github.com/opto-sync-test/gleam-wasm-fullstack-e2e)
- [Laravel Livewire / PHP + local Supabase](https://github.com/opto-sync-test/laravel-livewire-e2e)

These fixtures exercise durable browser service workers, native background
workers where the platform exposes them, immutable retries, concurrent upload
and realtime lanes, and recursively pinned OptoSync SDK/core revisions. The
Supabase fixture boots its own local stack and requires no hosted project key.

## Portfolio

| Repository | Class | Readiness | Primary dependency path |
|---|---|---|---|
Private repository details are intentionally withheld from this public document.

Pull requests run deterministic harness checks. Emulators, desktop matrices, live APIs/providers, databases, chaos, scale, and soaks are scheduled/manual. Missing upstreams or credentials are blocked readiness—not false passes or product regressions.

<!-- org-project-routing:start -->
## Planning and delivery

- [GitHub Project: opto-sync-test-project](https://github.com/orgs/opto-sync-test/projects/1)
- [Linear planning project](https://linear.app/denman/project/githubcomopto-sync-test-ab3f68a9b25a)
- [Detailed project-routing contract](../docs/PROJECTS.md)

GitHub owns code and delivery evidence; Linear owns planning and dependencies. The linked organization Project provides the cross-repository execution view.
<!-- org-project-routing:end -->


<!-- ore-org-baseline:begin -->
## Planning and governance

- Canonical Linear project: https://linear.app/denman/project/githubcomopto-sync-test-ab3f68a9b25a
- Organization defaults: https://github.com/opto-sync-test/.github
- Canonical agent policy: https://github.com/opto-sync-test/.github/blob/main/agents.md
- Security policy: https://github.com/opto-sync-test/.github/security/policy

Repositories in this organization use semantic conflict resolution with 3–10 relevant prior commits when useful, full cross-repository context, pull-request delivery, and a hard automated-agent denylist for destructive or history-rewriting operations.
<!-- ore-org-baseline:end -->

<!-- BEGIN MANAGED REPOSITORY RELATIONSHIPS v1 -->
## Repository relationship registry

`opto-sync-test` declares repository roles, dependency edges, cross-organization capabilities, deployment ownership, and the git-submodule/Zed-package contract:

- [Human-readable map](architecture/REPOSITORY_RELATIONSHIPS.md)
- [Machine-readable manifest](architecture/repository-relationships.json)
- [JSON Schema](architecture/repository-relationships.schema.json)

The public registry withholds private repository names and edges.
<!-- END MANAGED REPOSITORY RELATIONSHIPS v1 -->
