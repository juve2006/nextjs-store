---
id: adr-20260926-order-payment-outside-server-actions
type: adr
status: accepted
date: 2026-09-26
domains: []
paths:
  - lib/orders.ts
  - lib/actions/order.actions.ts
  - "app/api/webhooks/stripe/**"
summary: updateOrderToPaid lives in lib/orders.ts, outside 'use server', so only verified server paths can mark an order paid
---
# Marking an order paid lives in a plain server module, not in a server action file

## Context

`updateOrderToPaid` marks an order paid, takes the stock and sends the receipt. It trusts its
caller to have verified the payment. It lived in `lib/actions/order.actions.ts`, a
`'use server'` file, and the Stripe webhook imported it from there. Every export of such a
file is a server action that a browser can call directly, so a caller could have marked any
order paid without paying. Next 15 probably did not expose it, since no client component
used it, but that is a build optimisation, not a guarantee.

## Decision

`updateOrderToPaid` lives in `lib/orders.ts`, which has no `'use server'` directive. Only
server code reaches it by import: `approvePaypalOrder` after a matching capture,
`updateOrderToPaidCOD` after `requireAdmin()`, and the Stripe webhook after
`constructEvent` verified the signature. Any function that skips a check its callers make
follows the same placement.

## Alternatives

- Keep it exported from the action file and rely on Next dropping unused actions — rejected:
  safety would hang on a bundler detail nobody sees.
- Make it unexported — impossible: the webhook route needs to import it.
- Verify the payment inside it — rejected: the three providers verify differently, and the
  cash-on-delivery path has no provider at all.

## Consequences

Payment side effects (stock, receipt) are added in one place and reach all three payment
methods. A new payment path must verify first and then call this function; review checks
that no `'use server'` file re-exports it.
