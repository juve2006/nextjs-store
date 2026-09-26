  # Rules and Invariants

Normative requirements for this project. Rules say how work must be done; invariants say
what must always hold. Both are enforced in review and verification. Area-specific rules
are added as sections of this file.

## Invariants

- An order becomes paid only through `updateOrderToPaid` (`lib/orders.ts`), and only after
  the payment was verified: a matching PayPal capture, a Stripe-signed webhook, or an admin
  for cash on delivery. (adr-20260926-order-payment-outside-server-actions)
- Stock changes only when an order is paid, in the same transaction that marks it paid.
  (`lib/orders.ts`)
- An order is visible only to its owner or an admin: `getOrderById` returns `null` for anyone
  else. (`lib/actions/order.actions.ts`)
- Money leaves Prisma as a string: `db/prisma.ts` maps every `Decimal` field to a string.
  Compute with `Number()` and `round2` (`lib/utils.ts`), never on the raw values.
- An order's items keep the name, image and price they had at checkout. (`createOrder`)

## Rules

- Every admin-only server action calls `await requireAdmin()` as its first statement, before
  its `try`, so the redirect is not caught as an error. Admin pages are guarded by
  `app/admin/layout.tsx`. (adr-20260926-admin-authorization-in-actions)
- A function that skips a check its callers make — marking an order paid is the example —
  lives in a plain server module, never in a `'use server'` file. (adr-20260926-order-payment-outside-server-actions)
- Shapes are defined once in `lib/validators.ts`; types come from them through `z.infer`.
- Mutating server actions return `{ success, message }`, turn errors into messages with
  `formatError`, and call `revalidatePath` for the pages they change.
- Prisma results passed to client components go through `convertToPlainObject`.
- `auth.config.ts` stays importable in the edge runtime: no Prisma, no Node-only modules.
