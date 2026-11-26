#!/bin/sh
# 运行库由 Xcode 原生 Copy Files / CodeSignOnCopy 阶段嵌入并签名，此处只读校验。
set -eu
: "${TARGET_BUILD_DIR:?}" "${CONTENTS_FOLDER_PATH:?}"
agroom_runtime_target="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers/EmbeddingRuntime"

for agroom_arch in arm64 x86_64; do
    for agroom_helper in llama-embedding llama-intent; do
        agroom_entry="${agroom_runtime_target}/${agroom_arch}/${agroom_helper}"
        if ! test -x "${agroom_entry}"; then
            echo "error: Missing bundled inference runtime at ${agroom_entry}." >&2
            echo "error: Run scripts/prepare-knowledge-runtime.py, regenerate the Xcode project, then rebuild." >&2
            exit 1
        fi
        /usr/bin/codesign --verify --strict "${agroom_entry}"
    done
    for agroom_library in "${agroom_runtime_target}/${agroom_arch}/"*.dylib; do
        /usr/bin/codesign --verify --strict "${agroom_library}"
    done
done
