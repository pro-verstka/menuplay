#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <output-file>" >&2
    exit 1
fi

OUTPUT_FILE="$1"
CURRENT_SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
REF_NAME="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
BUILT_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"
REF_LABEL="Branch"
RANGE_END="$CURRENT_SHA"

build_commit_list() {
    local range="$1"
    while IFS= read -r subject; do
        case "$subject" in
            ci:*|ci\(*\):*)
                continue
                ;;
        esac

        printf -- "- %s\n" "$subject"
    done < <(git log --reverse --format='%s' "$range")
}

if [[ "$REF_NAME" == v* ]] && git rev-parse -q --verify "refs/tags/${REF_NAME}" >/dev/null 2>&1; then
    REF_LABEL="Tag"
    RANGE_END="$REF_NAME"
fi

if [[ "$RANGE_END" == v* ]]; then
    PREVIOUS_TAG="$(git describe --tags --abbrev=0 --exclude='rolling-main' "${RANGE_END}^" 2>/dev/null || true)"
else
    PREVIOUS_TAG="$(git describe --tags --abbrev=0 --exclude='rolling-main' "$CURRENT_SHA" 2>/dev/null || true)"
fi

if [ -n "$PREVIOUS_TAG" ]; then
    SECTION_TITLE="Commits since \`${PREVIOUS_TAG}\`"
    COMMITS="$(build_commit_list "${PREVIOUS_TAG}..${RANGE_END}")"
else
    SECTION_TITLE="Commits in repository history"
    COMMITS="$(build_commit_list "$RANGE_END")"
fi

if [ -z "$COMMITS" ]; then
    COMMITS="- No commits found for this release."
fi

cat > "$OUTPUT_FILE" <<EOF
Automated build from \`${CURRENT_SHA}\`.

- ${REF_LABEL}: \`${REF_NAME}\`
- Commit: \`${CURRENT_SHA}\`
- Built at: \`${BUILT_AT}\`
- Assets: \`MenuPlay-macos.zip\`, \`MenuPlay-macos.dmg\`

## ${SECTION_TITLE}

${COMMITS}

This build is unsigned and not notarized.
EOF
