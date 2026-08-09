#!/bin/bash

set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# build.sh normally exports both values before calling this file.
export ARCH="${ARCH:-arm}"
export CCACHE="${CCACHE:-false}"

source ./include/version.sh

TOOLCHAIN_ROOT="toolchain"
NDK_ROOT="$TOOLCHAIN_ROOT/ndk"
ARCH_ROOT="$TOOLCHAIN_ROOT/$ARCH"

if [[ ! -d "$NDK_ROOT" ]]; then
    mkdir -p "$TOOLCHAIN_ROOT"

    echo "==> Extracting Android NDK $NDK_VERSION"
    unzip -q "downloads/$NDK_FILE" -d "$TOOLCHAIN_ROOT/"

    extracted_ndk="$(find "$TOOLCHAIN_ROOT" -maxdepth 1 -type d -name 'android-ndk-*' | head -n 1)"
    if [[ -z "$extracted_ndk" ]]; then
        echo "Unable to find extracted Android NDK directory."
        exit 1
    fi

    mv "$extracted_ndk" "$NDK_ROOT"
fi

PREBUILT="$NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64"

if [[ ! -d "$PREBUILT/bin" ]]; then
    echo "Expected Linux x86_64 LLVM toolchain not found:"
    echo "  $PREBUILT"
    echo "The native build scripts are intended for Linux/WSL2."
    exit 1
fi

case "$ARCH" in
    arm)
        CLANG_TRIPLE="armv7a-linux-androideabi"
        ;;
    arm64)
        CLANG_TRIPLE="aarch64-linux-android"
        ;;
    x86)
        CLANG_TRIPLE="i686-linux-android"
        ;;
    x86_64)
        CLANG_TRIPLE="x86_64-linux-android"
        ;;
    *)
        echo "Unknown architecture: $ARCH"
        exit 1
        ;;
esac

PREBUILT_ABS="$(cd "$PREBUILT" && pwd)"
ARCH_ROOT_ABS="$(mkdir -p "$ARCH_ROOT" && cd "$ARCH_ROOT" && pwd)"
ARCH_BIN="$ARCH_ROOT_ABS/bin"

mkdir -p "$ARCH_BIN"
mkdir -p "$ARCH_ROOT_ABS/lib64"

echo "==> Creating NDK r26 compatibility toolchain for $ARCH (API $ANDROID_API)"

# Old OpenMW-Android scripts expect standalone-toolchain paths. NDK r26 no
# longer ships make_standalone_toolchain.py, so expose the unified sysroot and
# Clang runtime in the locations expected by build.sh.
ln -sfn "$PREBUILT_ABS/sysroot" "$ARCH_ROOT_ABS/sysroot"
ln -sfn "$PREBUILT_ABS/lib/clang" "$ARCH_ROOT_ABS/lib64/clang"

create_compiler_wrapper() {
    local output="$1"
    local compiler="$2"

    cat > "$output" <<EOF
#!/bin/bash
set -e
if [[ "\${CCACHE:-false}" == "true" ]]; then
    exec ccache "$compiler" "\$@"
else
    exec "$compiler" "\$@"
fi
EOF
    chmod +x "$output"
}

TARGET_CC="$PREBUILT_ABS/bin/${CLANG_TRIPLE}${ANDROID_API}-clang"
TARGET_CXX="$PREBUILT_ABS/bin/${CLANG_TRIPLE}${ANDROID_API}-clang++"

if [[ ! -x "$TARGET_CC" || ! -x "$TARGET_CXX" ]]; then
    echo "Target compiler driver not found for $ARCH / API $ANDROID_API"
    echo "  CC:  $TARGET_CC"
    echo "  CXX: $TARGET_CXX"
    exit 1
fi

create_compiler_wrapper "$ARCH_BIN/$NDK_TRIPLET-clang" "$TARGET_CC"
create_compiler_wrapper "$ARCH_BIN/$NDK_TRIPLET-clang++" "$TARGET_CXX"

# Some legacy dependency build systems still probe gcc/g++ names.
ln -sfn "$NDK_TRIPLET-clang" "$ARCH_BIN/$NDK_TRIPLET-gcc"
ln -sfn "$NDK_TRIPLET-clang++" "$ARCH_BIN/$NDK_TRIPLET-g++"

# Triple-prefixed binutils names were also present in old standalone toolchains.
declare -A BINUTILS=(
    [ar]="llvm-ar"
    [nm]="llvm-nm"
    [objcopy]="llvm-objcopy"
    [objdump]="llvm-objdump"
    [ranlib]="llvm-ranlib"
    [readelf]="llvm-readelf"
    [size]="llvm-size"
    [strings]="llvm-strings"
    [strip]="llvm-strip"
)

for legacy_name in "${!BINUTILS[@]}"; do
    llvm_name="${BINUTILS[$legacy_name]}"
    if [[ -x "$PREBUILT_ABS/bin/$llvm_name" ]]; then
        ln -sfn "$PREBUILT_ABS/bin/$llvm_name" "$ARCH_BIN/$NDK_TRIPLET-$legacy_name"
        ln -sfn "$PREBUILT_ABS/bin/$llvm_name" "$ARCH_BIN/$llvm_name"
    fi
done

# Useful LLVM tools that are invoked by parts of the existing build.
for llvm_name in ld.lld lld llvm-addr2line llvm-cxxfilt; do
    if [[ -x "$PREBUILT_ABS/bin/$llvm_name" ]]; then
        ln -sfn "$PREBUILT_ABS/bin/$llvm_name" "$ARCH_BIN/$llvm_name"
    fi
done

cp "$DIR/../patches/gas-preprocessor.pl" "$ARCH_BIN/gas-preprocessor.pl"
chmod +x "$ARCH_BIN/gas-preprocessor.pl"

if [[ "$CCACHE" == "true" ]] && ! command -v ccache >/dev/null 2>&1; then
    echo "CCACHE=true, but ccache is not installed."
    exit 1
fi

echo "==> NDK compatibility toolchain ready: $ARCH_ROOT_ABS"
