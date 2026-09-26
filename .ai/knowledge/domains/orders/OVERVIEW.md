---
id: domain-orders
type: domain
status: active
summary: "Orders and payments: cart to order, PayPal/Stripe/COD payment, delivery, stock and receipt"
domains:
  - orders
topics: []
load: domain
paths:
  - lib/actions/order.actions.ts
  - lib/orders.ts
  - lib/paypal.ts
  - "app/api/webhooks/stripe/**"
  - "app/(root)/order/**"
  - "app/(root)/place-order/**"
  - "app/(root)/payment-method/**"
  - "email/**"
  - "app/admin/orders/**"
---
# Orders and payments

## Responsibility

Turning a cart into an order and getting that order paid and delivered. (observed:
`createOrder`, `updateOrderToPaid`, `deliverOrder`) It is the only domain that changes stock
and the only one that sends email. (observed: `lib/orders.ts`, `email/`)

## Boundaries

- Reads the cart and the user's address and payment method; never edits a cart except to
  empty it inside `createOrder`. (observed)
- Talks to three outside systems: PayPal's REST API (`lib/paypal.ts`), Stripe (the order page
  creates a PaymentIntent; `app/api/webhooks/stripe/` receives `charge.succeeded`) and Resend
  (the receipt). (observed)
- Admin screens (`app/admin/orders/`) call into this domain; this domain knows nothing about
  them. (observed)

## Entry points

- `lib/actions/order.actions.ts` — creating, reading, listing, paying (PayPal, COD),
  delivering, deleting.
- `lib/orders.ts` — `updateOrderToPaid`, where every payment method ends.
- `app/(root)/order/[id]/` — the order page, PayPal and Stripe buttons, Stripe success page.
- `app/api/webhooks/stripe/route.ts` — Stripe's confirmation.
