# AirShare ADID API contract

The AirShare client now expects the existing `account.php` endpoint to support one additional authenticated action:

## `POST account.php`

Request:

```json
{
  "action": "admin_set_mdid",
  "token": "<authenticated-session-token>",
  "mdid": "AS-ABCDEF-23"
}
```

Requirements:

1. Authenticate `token` as a live AirShare account session.
2. Require the authenticated account to have the `admin` role server-side.
3. Validate the requested ADID as `AS-[A-Z0-9]{6}-[A-Z0-9]{2}`.
4. Reject a collision with another account/active device unless an explicit admin migration policy permits it.
5. Update the account's ADID and the ADID-based role/staff mapping atomically.
6. Write an audit record containing the admin account, old ADID, new ADID, and timestamp. Do not log passwords or session tokens.
7. Return the canonical ADID only after the transaction commits.

Success:

```json
{
  "ok": true,
  "mdid": "AS-ABCDEF-23"
}
```

Error examples should use an appropriate HTTP status and a JSON object such as:

```json
{
  "error": "ADID already belongs to another account"
}
```

## Why the client changes locally only after success

`AirShare` first asks the server to perform the administrative migration. If the server rejects it, the local ADID is untouched. After a successful response, AirShare writes the canonical ADID to Keychain and immediately re-checks the account profile and `roles/check.php` using the new ADID.

## First-launch behavior

New installations generate their ADID locally with `SecRandomCopyBytes`; the ADID is not derived from hardware identifiers. The ID is persisted in Keychain so the same installation keeps its identity until an authorized server-side reassignment occurs.
