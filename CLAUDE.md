# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

@AGENTS.md

## Commands

- `npm run dev` — dev server (Turbopack) on :3000
- `npm run lint` / `npm run build`
- `npm run start` locally needs `AUTH_TRUST_HOST=true`, or every auth route fails with `UntrustedHost`. Auth.js trusts the host automatically only on Vercel and under `next dev`.
- Agents run the app and tests against `.env.testing` (gitignored, created from `.env`), never `.env`: use `npm run dev:testing` / `npm run start:testing`. `npm test` loads `.env.testing` through `jest.setup.ts`. Node's `--env-file` sets these values first, and Next does not override variables that are already set.
- `npm test` — Jest via ts-jest. Single test: `npx jest tests/paypal.test.ts -t "creates a paypal order"`
- `npm run email` — react-email preview server for `email/` on :3001
- `npx prisma migrate dev --name <name>` after editing `prisma/schema.prisma`; `prisma generate` runs on `postinstall`
- `npx tsx ./db/seed` — seed from `db/sample-data.ts`

Env vars: copy `.example-env` to `.env`. `jest.setup.ts` loads `.env`, and `tests/paypal.test.ts` calls the real PayPal sandbox, so tests need valid `PAYPAL_*` credentials.

## Architecture

Next.js 15 App Router e-commerce store (React 19, Prisma on Neon Postgres, NextAuth v5, shadcn/ui in `components/ui`). Path alias `@/*` → repo root.

**Data access is server actions.** All reads/writes live in `lib/actions/*.actions.ts` (`'use server'`), called directly from server components and client forms. Mutations return `{ success, message }`, using `formatError` (`lib/utils.ts`) to turn Zod and Prisma errors into messages, then `revalidatePath` the affected pages. `app/api/` holds only NextAuth, Uploadthing, and the Stripe webhook.

**Zod schemas are the type source.** `lib/validators.ts` defines the schemas; `types/index.ts` derives the app types from them with `z.infer`. Change a shape in the validator, not the type.

**Money is a string.** `db/prisma.ts` extends the Prisma client so every `Decimal` field (product price/rating, cart and order prices, order item price) comes back as a string. Wrap Prisma results in `convertToPlainObject` before passing them to client components. Cart totals come from `calcPrice` in `cart.actions.ts`: free shipping over $100, 15% tax.

**Auth is split for the edge runtime.**
- `auth.config.ts` is edge-safe (no Prisma) and is all `middleware.ts` loads. Its `authorized` callback redirects unauthenticated users away from the protected-path regex list and sets the `sessionCartId` cookie for guests.
- `auth.ts` is the full config: Credentials provider (bcrypt), Prisma adapter, JWT sessions carrying `id`, `role`, `name`. On sign-in the `jwt` callback moves the guest cart (found by `sessionCartId`) onto the user.
- The middleware checks only that a user is signed in. The admin role is checked by `requireAdmin()` (`lib/auth-guards.ts`) in `app/admin/layout.tsx`, which covers every admin page. Server actions are public POST endpoints, so every admin-only action also calls `await requireAdmin()` as its first line, before its `try` block so the redirect isn't caught. Give any new admin action the same line.

**Checkout flow:** cart → `/shipping-address` → `/payment-method` → `/place-order` (`createOrder` copies the cart into an order) → `/order/[id]` to pay. The payment methods are PayPal, Stripe, and CashOnDelivery (set by `PAYMENT_METHODS`):
- PayPal: `createPaypalOrder` / `approvePaypalOrder` using `lib/paypal.ts`.
- Stripe: the order page creates a PaymentIntent with `metadata.orderId`; `app/api/webhooks/stripe/route.ts` handles `charge.succeeded`.
- COD: an admin marks the order paid (`updateOrderToPaidCOD`).

Every payment method ends in `updateOrderToPaid` (`lib/orders.ts`), which decrements stock in a transaction and emails the receipt through Resend (`email/`). Put payment side effects there so all three methods get them. It lives outside `lib/actions/` on purpose: every export of a `'use server'` file is a public action, and this function marks an order paid without checking that payment happened. Keep functions like it in plain server modules.

`getOrderById` returns `null` unless the caller owns the order or is an admin, so pages and actions that load an order through it get that check automatically.

Images upload through Uploadthing (`app/api/uploadthing/core.ts`) and are served from `utfs.io`, which is allowed in `next.config.ts`.
