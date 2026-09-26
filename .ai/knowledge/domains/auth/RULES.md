---
id: rule-auth
type: rule
status: active
summary: Role lives in the JWT until re-login; customer-only pages must be in the protected-path list
domains:
  - auth
topics: []
load: domain
requires: []
paths:
  - auth.ts
  - auth.config.ts
  - lib/auth-guards.ts
---
# Users and auth rules

## Invariants

- The session is a JWT (30 days); `role` is copied into the token only at sign-in.
  (observed: `auth.ts` `jwt` callback, `session.maxAge`) (inferred, high confidence) A role
  change — demoting an admin included — takes effect only after that user signs in again or
  the token expires.
- A customer-only page is protected only if its path matches the regex list in
  `auth.config.ts`. (observed)

## Rules

- (proposed) A new customer-only route is added to the protected-path list in
  `auth.config.ts` in the same change. Why: nothing else gates page login, and a typo there
  (`ordrer`) once left order pages open.
- (proposed) Anything that decides authorization reads the role from the database, not the
  token, when a stale role would be harmful. Open: whether `requireAdmin()` should do this.
