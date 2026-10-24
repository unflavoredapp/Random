# AirShare Premium: Litecoin payments

Premium is paid in Litecoin (LTC), inside the app. There is no payment company: the server only holds your
**extended public key**, derives a fresh receive address for every order, and watches the Litecoin blockchain through an
explorer API. The coins go straight to your wallet. The server can never spend them.

## 1. Set up your wallet key

1. Use a wallet you control that can show its **account-level extended public key** for a native SegWit (`ltc1q…`) wallet,
   for example Electrum-LTC (Wallet → Information → master public key). Any prefix is fine (`xpub`, `zpub`, `Ltub`).
   The server uses the key's first chain (the normal "receive" addresses) and makes `ltc1q…` addresses.
2. Put that public key in the server environment as `LTC_XPUB`.
   **Never** put a seed phrase or a private key (`xprv…`) on the server; the server refuses private keys on purpose.
3. Start the server. The log prints: `Litecoin payments on. Address #1 …`. Open your wallet and check that its receive address
   number 1 (second address, index 1 on the receive chain) is exactly that address. If it isn't, the key or path is wrong: stop and fix it
   before taking money.

Each order uses a new address (index = order number). Wallets only look a limited number of unused addresses ahead
("gap limit", usually 20). If many orders go unpaid in a row, a payment could sit beyond the gap. In Electrum-LTC
raise it with `wallet.change_gap_limit(100)` in the console, or recover with a larger gap limit.

## 2. Environment

| Variable | Default | Meaning |
| --- | --- | --- |
| `LTC_XPUB` | (required) | Extended **public** key. Payments are off without it. |
| `LTC_CONFS` | `2` | Confirmations needed before days are added (about 2.5 minutes each). |
| `LTC_QUOTE_MIN` | `30` | Minutes a quote (address + LTC amount) stays valid. |
| `LTC_TOLERANCE_PCT` | `1` | Short-payment tolerance (exchange fees). Max 5. |
| `LTC_POLL_SEC` | `30` | How often the server checks open orders. |
| `LTC_EXPLORER` | `https://litecoinspace.org/api` | Esplora-style explorer API; comma-separate several, they are tried in order. |
| `LTC_PRICE_URLS` | Coinbase + CoinGecko | LTC/USD price feeds. If two answer and differ by more than 5%, no quote is given. The lower price is used, so you never receive less than the USD price. |
| `LTC_PREMIUM_MAX_OPEN` | `5` | Unpaid open orders per user. |

Prices in USD live in `PLANS` in `payments.js`: 30 days $2.99, 90 days $7.99, 365 days $24.99.

## 3. How an order works

1. The app asks `POST /app/v1/checkout {plan}`. The server quotes LTC at the current price and returns an address, an exact
   amount, a payment URI and an expiry. The same plan again re-uses the open order.
2. The app shows a QR code, the amount, the address and a countdown, and asks `POST /app/v1/checkout/verify` every few seconds.
   The server also checks every `LTC_POLL_SEC` seconds on its own, so closing the app is fine.
3. Funds seen in the mempool show as "seen". Once the total received is at least the quoted amount (minus tolerance) with
   `LTC_CONFS` confirmations, the order becomes **paid** and the days are added exactly once.

Needs a person (shown in **/admin/payments**, never granted automatically):
- **late**: money arrived after the quote expired (the price may have moved).
- **underpaid**: less than the price arrived and nothing more came within 2 hours of expiry.
- **user_missing**: paid, but the account no longer exists.

Use **Grant** after checking the transaction in your wallet or an explorer. **Mark refunded** removes the days and marks the order;
Litecoin cannot be pulled back, so you send the coins back yourself.

## 4. Admin

`/admin/payments` (same Basic-auth login as `/admin/app`) lists orders with LTC asked / seen, confirmations and status.
Grant and refund need the `x-admin: 1` header, which the page sends.

## 5. Things to know

- Explorer trust: the server believes the explorer API. Use a reputable one (or run your own Esplora). Several in `LTC_EXPLORER`
  are only fallbacks, not a vote.
- Price volatility is on the quote window: LTC can move while an order is open. That is why 30 minutes is the default.
- Refunds are manual; there are no chargebacks.
- Distribution: if AirShare is ever listed on the App Store, Apple requires its own In-App Purchase for digital goods like Premium.

## 6. Testing

`tests/live/run.js` starts the real `appapi.js`, `payments.js`, `support.js` and `early.js` behind a small Express-compatible HTTP
server, with a fake Litecoin explorer and fake price feeds, and drives them over real HTTP (orders, confirmations, short/over/late
payments, explorer outages, grant/refund, Premium effects, and a 401/403 matrix over every `/admin` route). Node 22+:

    node tests/live/run.js

`ltc-hd.js` is checked against the official BIP84 test vectors in the same run.
