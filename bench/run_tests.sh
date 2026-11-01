#!/bin/bash
# The harness's own unit tests (no Mac state is touched).
set -euo pipefail
cd "$(dirname "$0")/tests"
exec python3 -I -m unittest discover -s . -p 'test_*.py' "$@"
