# AirCore Manual Patch Generator

This update adds a manual patch-definition workbench to Protection Analysis.

## Behavior
- Displays existing premium / StoreKit / entitlement findings in a dedicated selector.
- Lets the user manually enter an ARM64 virtual address, original bytes, proposed bytes, and rationale.
- Checks hexadecimal byte syntax, equal nonzero byte lengths, four-byte address alignment, and an explicit authorization confirmation.
- Generates a JSON patch *definition* for review.
- Does not infer or automatically propose a premium-unlock change, write bytes to the IPA, apply a patch, or modify the analyzed binary.

## Important limitations
- This is a definition builder, not a binary patch applier.
- Validation is structural only. It does not prove the proposed instructions are semantically correct, the target VA maps to the intended file offset, or the candidate is safe to apply.
- The user must verify the original bytes against the exact target binary and independently inspect CFG consequences before using a definition in an authorized workflow.
- Existing protection findings are static-analysis leads and are not proof that a premium gate exists at a particular address.
