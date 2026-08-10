## Purpose

Describe the problem, intended behavior, and why this repository owns the change.

## Scope and boundaries

- [ ] The change is focused and does not silently cross repository ownership boundaries.
- [ ] No `*-infra` repository is introduced as a Git submodule under `*-monorepo/apps`.
- [ ] Public contracts, migrations, compatibility, and roll-forward needs are documented.

## Test surface

- [ ] Source commits are immutable.
- [ ] Product assertions execute.
- [ ] Failure and recovery paths execute.
- [ ] Emulator, browser, and database matrices are justified.

## Validation

List formatters, linters, tests, builds, security checks, and manual verification performed.

## Safety

- [ ] No credentials, customer data, private-repository inventory, secrets, or raw private media are included.
- [ ] Conflicts were resolved semantically using both sides and relevant history.
- [ ] Destructive Git recovery and history rewrites were not used.
