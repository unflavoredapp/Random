# ADID identity model

## First launch

A new AirShare installation receives a cryptographically-random `AS-XXXXXX-XX` ADID on first use. The ID is stored in Keychain and is not derived from hardware, screen size, model, or other device fingerprints. Existing valid MDIDs are preserved for compatibility.

## Admin reassignment

Admins can change the ADID for their authenticated account from the Account screen. AirShare calls `POST account.php` with:

```json
{
  "action": "admin_set_mdid",
  "token": "<session token>",
  "mdid": "AS-XXXXXX-XX"
}
```

The server must authenticate the session as an administrator and atomically update the account's ADID plus any ADID-based role/staff mapping. It should reject collisions with another account/device unless an explicit administrative migration policy permits the change.

The response should contain the canonical ADID:

```json
{ "ok": true, "mdid": "AS-XXXXXX-XX" }
```

AirShare only writes the new ADID locally after receiving a valid server response, then refreshes the account profile and server-side role gate using the new ADID.

## Important

The ADID is an identifier, not a secret. Authorization must remain server-side. Do not treat possession of an ADID as proof of account ownership.
