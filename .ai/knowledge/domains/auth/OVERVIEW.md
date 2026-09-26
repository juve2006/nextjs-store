---
id: domain-auth
type: domain
status: active
summary: "Users and auth: edge/node split, JWT session with role, protected paths, admin guard, cart hand-over at sign-in"
domains:
  - auth
topics: []
load: domain
paths:
  - auth.ts
  - auth.config.ts
  - middleware.ts
  - lib/auth-guards.ts
  - lib/actions/user.actions.ts
  - "app/(auth)/**"
  - types/next-auth.d.ts
---
# Users and auth

## Responsibility

Who the visitor is and what they may do: credentials sign-in and sign-up, the JWT session
carrying `id`, `role` and `name`, the user's profile, address and payment method, and the
admin role. (observed: `auth.ts`, `lib/actions/user.actions.ts`)

## Boundaries

- Split for the edge runtime: `auth.config.ts` (loaded by `middleware.ts`) holds only what
  runs without the database — the protected-path list and the `sessionCartId` cookie;
  `auth.ts` holds the Prisma adapter, the credentials provider and the callbacks. (observed)
- On sign-in the `jwt` callback reaches into the cart domain: it deletes the user's cart and
  hands them the session cart. (observed) This is the one place auth writes another domain's
  data.
- Page login is gated by the regex list in `auth.config.ts`; admin role by `requireAdmin()`
  in `lib/auth-guards.ts`. (observed)

## Entry points

- `auth.ts`, `auth.config.ts`, `middleware.ts`
- `lib/auth-guards.ts`
- `lib/actions/user.actions.ts`
- `app/(auth)/` — sign-in and sign-up pages.
