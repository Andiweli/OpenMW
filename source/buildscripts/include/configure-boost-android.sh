#!/usr/bin/env bash
set -euo pipefail

BOOST_SOURCE_DIR="${1:?Boost source directory argument is required}"

if [[ -z "${CXX:-}" ]]; then
    echo "ERROR: Boost Android setup requires CXX from command_wrapper.sh." >&2
    exit 2
fi

CXX_PATH="$(command -v "$CXX" 2>/dev/null || true)"
if [[ -z "$CXX_PATH" || ! -x "$CXX_PATH" ]]; then
    echo "ERROR: Android CXX compiler '$CXX' is not executable in the dependency-build PATH." >&2
    echo "PATH=$PATH" >&2
    exit 2
fi

echo "Boost.Android: CXX=$CXX"
echo "Boost.Android: compiler=$CXX_PATH"
"$CXX_PATH" --version | head -n 1 || true

USER_CONFIG="$BOOST_SOURCE_DIR/android-user-config.jam"

# Boost.Build's clang-linux toolset otherwise falls back to a plain host
# `clang++`. Configure the already selected Android NDK C++ compiler explicitly.
#
# The NDK compiler wrapper already carries the Android target/API, therefore
# suppress B2's own target-triple inference.
cat > "$USER_CONFIG" <<EOF
using clang : : $CXX_PATH : <triple>none ;
EOF

echo "Boost.Android: wrote $USER_CONFIG"
cat "$USER_CONFIG"
