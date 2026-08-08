# Branching and deployment

## Canonical organization links

- GitHub organization: https://github.com/opto-sync-test
- Public organization defaults: https://github.com/opto-sync-test/.github
- Canonical Linear project: https://linear.app/denman/project/githubcomopto-sync-test-ab3f68a9b25a
- Fleet tracking issue: https://github.com/ORESoftware/k8s-cluster/issues/1222

Use additive feature or fix branches and pull requests. Preserve the repository's configured integration and release model, required reviews, branch protection, rulesets, security gates, and environment approvals. Deploy immutable, reviewed artifacts through the owning infrastructure and GitOps repositories; do not treat a source checkout as a production deployment mechanism.

Never force-push, rewrite shared history, bypass checks, or destroy state to advance a deployment. Prefer reversible roll-forward changes and document artifact identity, migration effects, observability, and recovery steps.
