#!/bin/bash
# Mer regression suite. Usage: ./Scripts/regression.sh [--scratch DIR] [--keep] [--mer PATH] [-k substr] [--list] [-j N] [-v]
# Builds the CLI (own scratch dir) unless --mer is given, generates all fixtures offline, runs the checks.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 2; }
command -v swiftc >/dev/null || { echo "swiftc (Xcode command line tools) is required" >&2; exit 2; }
exec python3 Scripts/regression.py "$@"
