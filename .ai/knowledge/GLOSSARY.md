# Glossary

Canonical ubiquitous language for this project. One entry per term. Use the canonical
term in source code, database schema, APIs, documentation and commit messages.

Entry format:

```
## <Canonical Term>

One-sentence definition.

Informal synonyms: <words people say instead>.
Use in: source code, schema, API, documentation.
```

## Session Cart

The cart of a visitor who has not signed in, found by the `sessionCartId` cookie that the
middleware sets on the first request; on sign-in it replaces the user's own cart.

Informal synonyms: guest cart, anonymous cart.
Use in: source code, documentation.

## Cart

The mutable list of items a visitor intends to buy, with prices recomputed on every change.

Informal synonyms: basket.
Use in: source code, schema, documentation.

## Order

An immutable snapshot of a cart at checkout: its order items copy name, slug, image and price,
so later product edits never change what was bought. Creating an order empties the cart.

Informal synonyms: purchase.
Use in: source code, schema, API, documentation.

## Payment Method

How an order is paid: exactly one of `PayPal`, `Stripe`, `CashOnDelivery`.

Informal synonyms: COD (for `CashOnDelivery`) — say `CashOnDelivery` in code and docs.
Use in: source code, schema, documentation.

## Payment Result

The provider's confirmation stored on a paid order (`paymentResult`: id, status, payer email,
amount paid).

Use in: source code, schema.

## Paid

An order state (`isPaid` with `paidAt`) meaning payment was verified and stock was taken.

Informal synonyms: completed.
Use in: source code, schema, documentation.

## Delivered

An order state (`isDelivered` with `deliveredAt`) set by an admin after shipping.

Use in: source code, schema, documentation.

## Admin

A user whose `role` is `admin`; the only other role is `user`.

Informal synonyms: staff, manager.
Use in: source code, schema, documentation.

## Server Action

An exported function of a `'use server'` file; every one is a publicly callable endpoint,
whoever the UI shows it to.

Use in: source code, documentation.
