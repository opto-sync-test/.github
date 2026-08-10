# Security policy

Never commit access tokens, keys, production credentials, production user data, raw biometric material, private messages, unencrypted private media or recordings, or unpublished provider credentials. Reproduce security failures with synthetic fixtures and report vulnerabilities privately to the production owner.

Pull-request jobs must be credential-free. Private cross-organization integration may use the organization-managed `TEST_FLEET_READ_TOKEN` only in explicitly gated workflows; it must never be printed, persisted in checkout configuration, or exposed to untrusted code.
