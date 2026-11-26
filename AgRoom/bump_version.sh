#!/bin/zsh
# bump_version.sh — 自动递增版本号（规范 §10）
# 用法：
#   ./bump_version.sh          递增构建号（CURRENT_PROJECT_VERSION +1）
#   ./bump_version.sh minor    递增次版本号并将构建号归 1
#   ./bump_version.sh major    递增主版本号并将构建号归 1
set -euo pipefail

PROJECT_YML="$(dirname "$0")/project.yml"
MODE="${1:-build}"

current_build=$(sed -n 's/^    CURRENT_PROJECT_VERSION: "\([0-9]*\)"$/\1/p' "$PROJECT_YML")
current_marketing=$(sed -n 's/^    MARKETING_VERSION: "\([0-9.]*\)"$/\1/p' "$PROJECT_YML")

if [[ -z "$current_build" || -z "$current_marketing" ]]; then
    echo "error: cannot locate MARKETING_VERSION / CURRENT_PROJECT_VERSION in $PROJECT_YML" >&2
    exit 1
fi

case "$MODE" in
    build)
        new_build=$((current_build + 1))
        new_marketing="$current_marketing"
        ;;
    minor|major)
        IFS='.' read -r major minor patch <<< "$current_marketing"
        patch="${patch:-0}"
        if [[ "$MODE" == "major" ]]; then
            new_marketing="$((major + 1)).0.0"
        else
            new_marketing="${major}.$((minor + 1)).0"
        fi
        new_build=1
        ;;
    *)
        echo "usage: $0 [build|minor|major]" >&2
        exit 1
        ;;
esac

sed -i '' "s/^    CURRENT_PROJECT_VERSION: \"[0-9]*\"$/    CURRENT_PROJECT_VERSION: \"$new_build\"/" "$PROJECT_YML"
sed -i '' "s/^    MARKETING_VERSION: \"[0-9.]*\"$/    MARKETING_VERSION: \"$new_marketing\"/" "$PROJECT_YML"

echo "bumped: MARKETING_VERSION=$new_marketing CURRENT_PROJECT_VERSION=$new_build"
