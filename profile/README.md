# opto-sync-test

Independent acceptance organization for **opto-sync**.

IndexedDB/SQLite/PostgreSQL/Supabase sync, conflicts, background execution, validators, and Rust/C conformance.

## Portfolio

| Repository | Class | Readiness | Primary dependency path |
|---|---|---|---|
| `indexeddb-postgres-sync` | synchronization | `ready` | `matrix` |
| `sqlite-postgres-sync` | synchronization | `ready` | `matrix` |
| `supabase-sync` | synchronization | `ready` | `matrix` |
| `conflict-resolution` | protocol conformance | `ready` | `matrix` |
| `offline-background` | mobile/emulator | `ready` | `matrix` |
| `zod-validation` | SDK consumer | `ready` | `matrix` |
| `serde-validation` | SDK consumer | `ready` | `matrix` |
| `dart-validation` | SDK consumer | `ready` | `matrix` |
| `gleam-validation` | SDK consumer | `ready` | `matrix` |
| `go-java-validation` | SDK consumer | `ready` | `matrix` |
| `chaos-property-conformance` | chaos/fault injection | `ready` | `matrix` |

Pull requests run deterministic harness checks. Emulators, desktop matrices, live APIs/providers, databases, chaos, scale, and soaks are scheduled/manual. Missing upstreams or credentials are blocked readiness—not false passes or product regressions.

<!-- org-project-routing:start -->
## Planning and delivery

- [GitHub Project: opto-sync-test-project](https://github.com/orgs/opto-sync-test/projects/1)
- [Linear planning project](https://linear.app/denman/project/githubcomopto-sync-test-ab3f68a9b25a)
- [Detailed project-routing contract](../docs/PROJECTS.md)

GitHub owns code and delivery evidence; Linear owns planning and dependencies. The linked organization Project provides the cross-repository execution view.
<!-- org-project-routing:end -->
