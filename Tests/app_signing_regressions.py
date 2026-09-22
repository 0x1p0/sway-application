"""Disposable two-version identities; never execute fixtures or request TCC access."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("signing", ROOT / "scripts/app-signing.py")
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
checks = 0


def expect(condition, message):
    global checks
    assert condition, message
    checks += 1


def reject(action, message):
    try:
        action()
    except Exception:
        expect(True, message)
        return
    raise AssertionError(message)


def run(*args):
    return subprocess.run(args, check=True, capture_output=True).stdout


with tempfile.TemporaryDirectory(prefix="sway-code-sign-tests.") as temporary:
    work = Path(temporary)
    before_keychains = run("/usr/bin/security", "list-keychains", "-d", "user")
    config = work / "certificate.cnf"
    config.write_text("[req]\ndistinguished_name=dn\n[dn]\nCN=Sway Test\n[signing]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,digitalSignature,keyCertSign\nextendedKeyUsage=codeSigning\n")
    password = "disposable-signing-test-password-only"

    def identity(name):
        key, pem, cert, p12 = [work / f"{name}.{suffix}" for suffix in ("key", "pem", "cer", "p12")]
        run("/usr/bin/openssl", "req", "-new", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256", "-days", "2",
            "-subj", f"/CN={name}/", "-config", str(config), "-extensions", "signing", "-keyout", str(key), "-out", str(pem))
        run("/usr/bin/openssl", "x509", "-in", str(pem), "-outform", "DER", "-out", str(cert))
        run("/usr/bin/openssl", "pkcs12", "-export", "-inkey", str(key), "-in", str(pem), "-name", name,
            "-keypbe", "PBE-SHA1-3DES", "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1", "-passout", "pass:" + password, "-out", str(p12))
        return cert, {"pkcs12": base64.b64encode(p12.read_bytes()).decode(), "password": password}

    cert, payload = identity("Sway Test")
    other_cert, other_payload = identity("Different Signer")

    def fixture(name, version):
        bundle = work / f"{name}.app"
        (bundle / "Contents/MacOS").mkdir(parents=True)
        (bundle / "Contents/Resources").mkdir()
        source = work / f"{name}.c"
        source.write_text(f"int main(void) {{ return {version}; }}\n")
        run("/usr/bin/xcrun", "clang", "-arch", "arm64", "-arch", "x86_64", str(source), "-o", str(bundle / "Contents/MacOS/Sway"))
        metadata = plistlib.loads((ROOT / "Sway/Info.plist").read_bytes())
        metadata.update(CFBundleIdentifier=signing.IDENTIFIER, CFBundleExecutable="Sway", CFBundleName="Sway", CFBundlePackageType="APPL")
        if version != 1:
            metadata["CFBundleVersion"] = str(int(metadata["CFBundleVersion"]) + version)
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
        (bundle / "Contents/Resources/fixture.txt").write_text(name)
        return bundle

    first, second = fixture("first", 1), fixture("second", 2)
    signing.sign(first, payload, cert)
    signing.sign(second, payload, cert)
    # sign() removes its temporary keychain before verify(). Both builds must
    # validate without any installed certificate, user trust, or private key.
    for bundle in (first, second):
        signing.verify(bundle, cert)
        expect(True, "both versions validate against the same pinned requirement")
    expect((first / "Contents/MacOS/Sway").read_bytes() != (second / "Contents/MacOS/Sway").read_bytes(), "fixtures contain different executable code")
    expect(signing.requirement(cert) not in signing.requirement(other_cert), "unrelated signer has a different requirement")
    reject(lambda: signing.verify(first, other_cert), "wrong certificate must fail")
    impostor = fixture("impostor", 1)
    signing.sign(impostor, other_payload, other_cert)
    reject(lambda: signing.verify(impostor, cert), "same bundle ID under another signer must fail")
    weakened = fixture("weakened-requirement", 1)
    original_requirement = signing.requirement
    try:
        signing.requirement = lambda *args: 'identifier "com.trackpadcontrol.app"'
        signing.sign(weakened, payload, cert)
    finally:
        signing.requirement = original_requirement
    reject(lambda: signing.verify(weakened, cert), "even the correct signer must declare a certificate-bound requirement")
    (second / "Contents/Resources/fixture.txt").write_text("tampered")
    reject(lambda: signing.verify(second, cert), "tampered resources must fail")
    unsigned = fixture("ad-hoc", 1)
    run("/usr/bin/codesign", "--force", "--sign", "-", "--options", "runtime", "--timestamp=none",
        "--requirements", '=designated => identifier "com.trackpadcontrol.app"', "--entitlements", str(ROOT / "Sway/Sway.entitlements"), str(unsigned))
    reject(lambda: signing.verify(unsigned, cert), "identifier-only ad-hoc workaround must fail")
    reject(lambda: signing.sign(unsigned, other_payload, cert), "private identity must match the public certificate pin")
    env = os.environ.copy()
    env["CI"] = "true"
    env.pop(signing.SECRET, None)
    missing = subprocess.run(["python3", str(ROOT / "scripts/app-signing.py"), "sign", str(unsigned)], env=env, capture_output=True)
    expect(missing.returncode != 0, "CI may never fall back to a local/ad-hoc identity")
    sentinel = "PRIVATE_TEST_VALUE_MUST_NOT_APPEAR_IN_LOGS"
    env[signing.SECRET] = sentinel
    malformed = subprocess.run(["python3", str(ROOT / "scripts/app-signing.py"), "sign", str(unsigned)], env=env, capture_output=True)
    expect(malformed.returncode != 0 and sentinel.encode() not in malformed.stdout + malformed.stderr, "malformed secret fails without credential disclosure")
    expect(run("/usr/bin/security", "list-keychains", "-d", "user") == before_keychains, "temporary keychains must leave the search list unchanged")

print(f"{checks} app-identity assertions passed with disposable keys and two different universal builds. No fixture ran; no TCC or trust settings changed.")
