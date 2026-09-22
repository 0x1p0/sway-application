#!/bin/bash
set -euo pipefail
bundle="${1:?Pass an app bundle}"
metadata="$(codesign -d --verbose=2 "$bundle" 2>&1)"
if [[ "$metadata" != *"runtime)"* ]]; then
    printf 'Hardened Runtime is missing from the app signature.\n' >&2
    exit 1
fi
entitlements="$(codesign -d --entitlements :- "$bundle" 2>/dev/null)"
# plutil ships with macOS; package-manager tools are not guaranteed on CI.
# Compare the complete parsed dictionary, not a blacklist of known exceptions.
entitlements_json="$(printf '%s' "$entitlements" | /usr/bin/plutil -convert json -o - -)"
if [[ "$entitlements_json" != '{"com.apple.security.cs.disable-library-validation":true}' ]]; then
    printf 'Expected only the documented library-validation entitlement, with boolean true.\n' >&2
    exit 1
fi
printf 'Hardened Runtime verified; only the documented cross-signer library-validation exception is present.\n'
