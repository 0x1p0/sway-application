# Persistent app identity

`Sway.cer` is the public DER certificate for release app signing. Its subject is
`CN=Sway`. It is safe to publish; it contains no private key, personal name, or
email. It is a self-issued, code-signing-only root (path length zero), not an
Apple Developer ID certificate. Users do not need to install this certificate
or change their trust settings. It does not remove Gatekeeper's warning.

The private PKCS#12 identity and wrapping password are stored as one protected
item in the maintainer's login Keychain:

- Service: `com.sway.app-signing`
- Account: `sway-application-0x1p0`
- Label: `Sway persistent app signing identity`

GitHub Actions receives the same identity only through `SWAY_APP_SIGNING_IDENTITY`
in the approval-protected `release` environment. It is not a repository-level
secret. Never print it, commit it, or regenerate it during a build. Keep an
encrypted offline backup through a secure credential-management process.

The designated requirement pins both `com.trackpadcontrol.app` and this exact
certificate. Release verification checks every executable architecture and
compares the embedded certificate bytes with this file. Do not replace this
with a bundle-identifier-only requirement: anyone could imitate that identity.
The certificate is valid until September 2046; plan an explicitly tested
migration before expiry. A lost/compromised key or changed certificate may
require users to grant permissions again. This self-signed identity has no
Apple-managed revocation service.

This key is separate from `SPARKLE_PRIVATE_KEY`, which authenticates the update
feed and ZIP. Local release packaging reads both identities from Keychain;
`SWAY_DEFER_UPDATE_SIGNING=1` skips only the update signature, not app signing.
`scripts/build.sh` remains a key-free ad-hoc development build and is not a
permission-preserving release. Never replace the installed release with it
when testing permission continuity.

To inspect the public identity:

```sh
openssl x509 -inform DER -in scripts/signing/Sway.cer -noout -subject -issuer -dates -fingerprint -sha256
codesign --display -r - /Applications/Sway.app
python3 scripts/app-signing.py verify build/Sway.app
```

The two-version signing regression uses disposable certificates and never
launches its fixtures. A real TCC test is distinct: install the first persistent
release, grant Accessibility once, install a newer release signed by this same
identity into the same location, and confirm gestures work without editing the
Accessibility entry. Do not reset TCC, remove the permission entry, switch to an
ad-hoc build, or install a certificate during that test.
