## ADID identity

New installations mint a cryptographically-random `AS-XXXXXX-XX` ADID on first use. The ID is stored in Keychain and is not derived from hardware or display fingerprints.

Administrators can reassign the ADID of their authenticated admin account from Settings → Account. The app calls `account.php` with `action=admin_set_mdid`; the server must atomically update the account ADID and its ADID-based role mapping before returning the canonical ADID. AirShare only changes its local Keychain value after that server response.

See `MDID_IDENTITY.md` for the API contract.

## Local Analysis Center

The AVX512/AirShare analysis stack is local-first and does not require a remote analysis service. The same annotated `UCFunction` feeds the Disassembler Browser, CFG Viewer, Pseudocode Viewer, and Analysis Center.

Analysis Center currently exposes:
- Overview / local analysis statistics
- String annotations
- Resolved symbols/classes/methods
- Function/call inspection
- Basic-block graph edges
- Call/branch/XREF flow
- Hex/memory view of decoded function bytes
- Reversible local NOP/RET patch proposals and patch manifest export
- Original-vs-proposed patch diff
- One-tap navigation back to Disassembler, CFG, and Pseudocode

Patch proposals are deliberately kept as an in-memory/local manifest in this viewer; the source binary is not modified by opening the analysis UI.

yur

## Native install

AirShare can install signed apps directly on-device (built-in local VPN + device pairing) as an alternative to OTA.
Settings › Install Method. See `NATIVE_INSTALL.md`.
