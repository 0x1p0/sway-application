#!/bin/bash
# Isolate the pinned, build-only Finder-layout dependencies from system Python.
set -euo pipefail
script_directory="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_directory="$(cd -- "$script_directory/.." && pwd)"
environment="$project_directory/build/DmgTools"
if [[ ! -x "$environment/bin/python" ]]; then
    python3 -m venv "$environment"
fi
"$environment/bin/python" -m pip install --disable-pip-version-check --require-hashes --only-binary=:all: \
    -r "$script_directory/dmg-requirements.txt"
"$environment/bin/python" -m pip check
