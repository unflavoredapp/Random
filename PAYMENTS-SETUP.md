# AirShare premium payments (Stripe)

Server side adds `server/payments.js` and one hook in `server/appapi.js`. No new npm packages (Node 18+).

## Env (server)
```
STRIPE_SECRET_KEY=sk_test_...        # start with test keys
STRIPE_WEBHOOK_SECRET=whsec_...
PUBLIC_BASE_URL=https://airshare.lol
```
Without the first two, payments stay off and the rest of the server runs as before.

## Stripe dashboard
1. Developers > Webhooks > add endpoint `https://airshare.lol/stripe/webhook`.
2. Events: `checkout.session.completed`, `checkout.session.async_payment_succeeded`, `charge.refunded`.
3. Copy its signing secret into `STRIPE_WEBHOOK_SECRET`.
4. Settings > Payment methods: turn on Apple Pay and cards.
5. If a reverse proxy sits in front of Node, do not let it rewrite or parse `/stripe/webhook` bodies.

## Edit before launch
- Plans and prices: `PLANS` at the top of `server/payments.js`.
- Terms link and "what to know" text: `Sources/PremiumStoreView.swift`.
- `showsBadgePerk` in `PremiumStoreView.swift`: set to true once a premium badge really shows next to usernames
  (`badgesOf` in appapi.js does not add one today).

## Flow
App `POST /app/v1/checkout {plan}` -> server creates a Stripe Checkout session -> app opens it in Safari ->
Stripe webhook -> server adds the plan's days with the existing `setPremium(id, "add", days)` once per session
-> app refreshes premium status. Refunds mark the record `refunded` but leave the days; revoke from /admin/app if wanted.
