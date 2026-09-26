---
id: adr-20260926-admin-authorization-in-actions
type: adr
status: accepted
date: 2026-09-26
domains: []
paths:
  - "lib/actions/**"
  - lib/auth-guards.ts
  - "app/admin/**"
summary: Every admin server action calls requireAdmin() first; the admin layout guards pages; getOrderById checks ownership
---
# Admin authorization is checked in every admin server action and in the admin layout

## Context

The middleware (`auth.config.ts`) only checks that someone is signed in. Admin pages checked
the role one by one, and several did not, while the admin server actions — `updateUser`,
`deleteProduct`, `deleteOrder` and the rest — checked nothing. Server actions are public
endpoints, so any visitor could call `updateUser` and make themselves an admin; hiding the
admin UI did not stop that.

## Decision

Every admin-only server action calls `await requireAdmin()` (`lib/auth-guards.ts`) as its
first statement, before its `try`, so the redirect is not swallowed as an error message.
`app/admin/layout.tsx` calls it once for every admin page. Order reads check ownership in
`getOrderById`: owner or admin.

## Alternatives

- Role check in the middleware — rejected: the middleware runs on the edge without the
  database and does not cover direct action calls, which are POSTs to the page URL.
- A check on each admin page only — rejected: pages are not the attack surface; actions are.
- A wrapper such as `adminAction(fn)` — rejected for now: one line per action is as short
  and easier to see in review.

## Consequences

A new admin action without the line is a security bug; review looks for it. The layout guard
does not re-run on client-side navigation inside `/admin`, which is acceptable because the
actions and data reads are guarded themselves.
