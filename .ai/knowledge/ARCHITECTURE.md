
# Architecture

High-level map of the system. Describe engineering intent, not implementation:
what the domains are, where the boundaries lie, which direction dependencies may point,
and which constraints and invariants hold system-wide. Anything the code already says
does not belong here.

A single Next.js App Router application: a storefront for customers and an admin area for
staff, backed by one PostgreSQL database (Neon) through Prisma.

## Domains

- **Catalog** — products, categories, featured banners, search. `lib/actions/product.actions.ts`.
  Knows nothing about carts or orders.
- **Cart** — the session cart and the signed-in user's cart, and their prices.
  `lib/actions/cart.actions.ts`. Reads the catalog for stock and price.
- **Orders and payments** — turning a cart into an order, paying it through PayPal, Stripe or
  cash on delivery, delivery. `lib/actions/order.actions.ts`, `lib/orders.ts`, `lib/paypal.ts`,
  `app/api/webhooks/stripe/`. The only domain that changes stock.
- **Users and auth** — credentials sign-in, sessions, roles, profile, shipping address.
  `auth.ts`, `auth.config.ts`, `lib/actions/user.actions.ts`, `lib/auth-guards.ts`.
- **Reviews** — one review per user per product; keeps the product's rating current.
  `lib/actions/review.actions.ts`.
- **Admin** — screens over the other domains; owns no data. `app/admin/`.
- **Email** — the purchase receipt. `email/`. Triggered only by orders.

## Boundaries and dependency direction

UI (`app/`, `components/`) → server actions (`lib/actions/`) → `db/prisma.ts`. Pages and
components read and mutate through server actions, never through Prisma directly; the Stripe
webhook is the one route handler that mutates, and it goes through `lib/orders.ts`.

`lib/validators.ts` (Zod) is the source of shapes; `types/` derives from it and nothing derives
the other way.

`auth.config.ts` runs in the edge middleware, so it must not import Prisma or Node-only code;
everything that needs the database lives in `auth.ts`.

## Runtime flows

1. **Session cart to user cart.** The middleware gives every visitor a `sessionCartId` cookie;
   items go into the cart for that id. On sign-in the `jwt` callback deletes the user's old
   cart and assigns the session cart to the user.
2. **Checkout.** cart → `/shipping-address` → `/payment-method` → `/place-order`, where
   `createOrder` copies the cart into an order and its items in one transaction and empties
   the cart → `/order/[id]` to pay.
3. **Payment.** PayPal (capture checked against the stored PayPal order id), Stripe (webhook
   `charge.succeeded`, signature verified) and cash on delivery (an admin marks it paid) all
   end in `updateOrderToPaid`, which decrements stock and marks the order paid in one
   transaction, then emails the receipt.

## System-wide constraints and invariants

See `RULES.md`. The authorization model — public server actions, so the check sits in each
action — is recorded in adr-20260926-admin-authorization-in-actions; where payment is confirmed, in
adr-20260926-order-payment-outside-server-actions.
