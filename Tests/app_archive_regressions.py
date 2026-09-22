import importlib.util
from pathlib import Path
import stat
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("archive", ROOT / "scripts/safe-app-archive.py")
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)
checks = 0

with tempfile.TemporaryDirectory(prefix="sway-archive-tests.") as temporary:
    root = Path(temporary)

    def check(entries, accepted):
        global checks
        checks += 1
        path = root / f"{checks}.zip"
        with zipfile.ZipFile(path, "w") as output:
            for name, mode, content in entries:
                entry = zipfile.ZipInfo(name)
                entry.create_system = 3
                entry.external_attr = mode << 16
                output.writestr(entry, content)
        try:
            archive.extract(path, root / f"extracted-{checks}")
        except Exception:
            assert not accepted, "valid archive rejected"
        else:
            assert accepted, "unsafe archive accepted"

    file, directory, link = stat.S_IFREG | 0o644, stat.S_IFDIR | 0o755, stat.S_IFLNK | 0o777
    base = [("Sway.app/", directory, ""), ("Sway.app/Contents/file", file, "safe")]
    check(base, True)
    check(base + [("Sway.app/alias", link, "Contents/file")], True)
    for entry in [
        ("../outside", file, "bad"), ("/absolute", file, "bad"), ("Other.app/file", file, "bad"),
        ("Sway.app/../outside", file, "bad"), ("Sway.app//duplicate", file, "bad"),
        ("Sway.app/CONTENTS/FILE", file, "bad"), ("Sway.app/pipe", stat.S_IFIFO | 0o644, "bad"),
        ("Sway.app/setuid", file | stat.S_ISUID, "bad"), ("Sway.app/link", link, "/Applications"),
        ("Sway.app/link", link, "../../outside"), ("Sway.app/link", link, "missing"),
    ]:
        check(base + [entry], False)
    check(base + [("Sway.app/link", link, "Contents"), ("Sway.app/link/file2", file, "bad")], False)
    check(base + [("Sway.app/one", link, "two"), ("Sway.app/two", link, "one")], False)
    check([("Sway.app", link, "elsewhere")], False)
    check([], False)

print(f"{checks} bounded-archive assertions passed; no app code executed.")
