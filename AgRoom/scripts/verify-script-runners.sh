#!/bin/sh
set -eu

# 各 target 按自己的 entitlements 签名，Xcode 原生 Copy Files 阶段原样嵌入。
# 本脚本只读校验最终副本；不使用 --deep 重签，避免覆盖执行器的独立权限。
agroom_helpers="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Helpers"
for agroom_runner in AgRoomRunnerPersonal AgRoomRunnerWork; do
    agroom_source="${agroom_helpers}/${agroom_runner}.app"
    test -d "${agroom_source}"
    /usr/bin/codesign --verify --strict "${agroom_source}"
done
