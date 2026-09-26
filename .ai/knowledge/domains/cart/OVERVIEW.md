---
id: domain-cart
type: domain
status: active
summary: "Cart: session vs user cart, price calculation, stock checked but not reserved"
domains:
  - cart
topics: []
load: domain
paths:
  - lib/actions/cart.actions.ts
  - "app/(root)/cart/**"
  - components/shared/product/add-to-cart.tsx
---
# Cart

## Responsibility

The items a visitor intends to buy and their prices, for a signed-in user or for a
session cart identified by the `sessionCartId` cookie. (observed: `lib/actions/cart.actions.ts`)

## Boundaries

- Prices are recomputed from the items on every change by `calcPrice`: free shipping over
  $100, otherwise $10; tax 15% of items. (observed) The order copies these totals and never
  recomputes them. (observed: `createOrder`)
- Adding an item checks the product's stock, but nothing is reserved: stock drops only when
  an order is paid. (observed: `addItemToCart`, `lib/orders.ts`) (inferred) Two carts can
  therefore hold the last unit, and both orders can be paid.
- Session cart to user cart happens in the auth domain, at sign-in. (observed: `auth.ts`)

## Entry points

- `lib/actions/cart.actions.ts`
- `app/(root)/cart/`
- `components/shared/product/add-to-cart.tsx`
