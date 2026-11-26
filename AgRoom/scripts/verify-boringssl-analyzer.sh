#!/bin/sh
set -eu

# Keep the vendored patch reproducible with the selected Xcode toolchain.
agroom_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
agroom_boringssl="${agroom_root}/vendor/swift-nio-ssl/Sources/CNIOBoringSSL"
agroom_clang=$(xcrun --find clang++)
agroom_sdk=$(xcrun --sdk macosx --show-sdk-path)
agroom_scratch=$(mktemp -d "${TMPDIR:-/tmp}/agroom-boringssl-analyzer.XXXXXX")
trap 'rm -rf "$agroom_scratch"' EXIT
trap 'exit 1' HUP INT TERM

for agroom_mode in shallow deep; do
    for agroom_configuration in debug release; do
        if [ "$agroom_configuration" = debug ]; then
            set -- -DDEBUG=1
        else
            set -- -DNDEBUG
        fi
        for agroom_source in \
            crypto/curve25519/curve25519.cc \
            crypto/fipsmodule/bcm.cc \
            crypto/pem/pem_lib.cc \
            crypto/pem/pem_pk8.cc \
            crypto/pem/pem_pkey.cc \
            crypto/pkcs8/pkcs8.cc \
            crypto/x509/by_dir.cc \
            ssl/ssl_aead_ctx.cc \
            ssl/ssl_cipher.cc; do
            agroom_log="${agroom_scratch}/analysis.log"
            if ! "$agroom_clang" --analyze -std=c++17 -isysroot "$agroom_sdk" \
                -mmacosx-version-min=15.0 "$@" -D_GNU_SOURCE \
                -D_POSIX_C_SOURCE=200112L -D_DARWIN_C_SOURCE \
                -I "${agroom_boringssl}/include" -Wno-shorten-64-to-32 \
                -Xanalyzer -analyzer-config -Xanalyzer "mode=${agroom_mode}" \
                -Xanalyzer -analyzer-output=text -o /dev/null \
                "${agroom_boringssl}/${agroom_source}" > "$agroom_log" 2>&1; then
                cat "$agroom_log"
                exit 1
            fi
            # Analyzer warnings do not necessarily make clang return nonzero.
            if /usr/bin/grep -q 'warning:' "$agroom_log"; then
                cat "$agroom_log"
                exit 1
            fi
        done
    done
done
printf '%s\n' 'BoringSSL analyzer checks passed.'
