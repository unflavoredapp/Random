# AirShare ↔ AVX512 signing bridge

For elevated staff/admin accounts, the Signing Sheet can persist an AVX512 dylib and
automatically attach it to the IPA being signed when the AVX512 Experimental toggle is enabled.

The signed app receives `AVX512.msign.json` containing only:
- ADID
- role
- bundle ID
- app name
- source
- timestamp

No certificate, P12, private key, password, or signing secret crosses the bridge.

The AVX512 dylib reads this manifest at launch and displays the ADID in its Menu top bar.

## Important
The AVX512 source archive is source code, not a compiled `.dylib`. The staff member must
select the compiled AVX512 dylib once in the Signing Sheet; AirShare then stores it in
Application Support and automatically attaches it to subsequent enabled staff/admin signing jobs.
