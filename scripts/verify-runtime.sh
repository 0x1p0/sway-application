#!/bin/bash
set -euo pipefail
bundle="${1:?Pass an app bundle}"
metadata="$(codesign -d --verbose=2 "$bundle" 2>&1)"
if [[ "$metadata" != *"runtime)"* ]]; then
    printf 'Hardened Runtime is missing from the app signature.\n' >&2
    exit 1
fi
entitlements="$(codesign -d --entitlements :- "$bundle" 2>/dev/null)"
printf '%s' "$entitlements" | plutil -extract 'com\.apple\.security\.cs\.disable-library-validation' raw - | rg -qx true
if printf '%s' "$entitlements" | rg -q 'get-task-allow|allow-jit|allow-unsigned-executable-memory|disable-executable-page-protection|allow-dyld-environment-variables|automation.apple-events'; then
    printf 'Unexpected runtime exception in release signature.\n' >&2
    exit 1
fi
printf 'Hardened Runtime verified; only the documented ad-hoc library-validation exception is present.\n'
