---
id: rule-orders
type: rule
status: active
summary: Payment verification invariants (PayPal capture match, Stripe signature, no double pay) and how to add a payment method
domains:
  - orders
topics: []
load: domain
requires: []
paths:
  - lib/actions/order.actions.ts
  - lib/orders.ts
  - "app/api/webhooks/stripe/**"
  - "app/(root)/order/**"
---
# Orders and payments rules

## Invariants

- A PayPal payment counts only when the capture id equals the PayPal order id stored on the
  order by `createPaypalOrder` and its status is `COMPLETED`. (observed: `approvePaypalOrder`)
- The Stripe webhook acts only on an event whose signature `constructEvent` verified with
  `STRIPE_WEBHOOK_SECRET`; the order it pays comes from the PaymentIntent's
  `metadata.orderId`. (observed: `app/api/webhooks/stripe/route.ts`, `order/[id]/page.tsx`)
- Paying an order twice is refused: `updateOrderToPaid` throws when `isPaid` is already true.
  (observed: `lib/orders.ts`)

## Rules

- (proposed) A new payment method verifies the payment with its provider, then calls
  `updateOrderToPaid`; it never sets `isPaid` itself. Why: stock and the receipt live there,
  and a second path would skip them.
- (proposed) Amounts sent to a provider are computed from the order's stored `totalPrice`,
  never from anything the client sends. (observed for PayPal and Stripe today)
