#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <output-file>" >&2
    exit 1
fi

OUTPUT_FILE="$1"
CURRENT_SHA="${GITHUB_SHA:-$(git rev-parse HEAD)}"
BRANCH_NAME="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD)}"
BUILT_AT="$(date -u +"%Y-%m-%d %H:%M:%S UTC")"

if PREVIOUS_TAG=$(git describe --tags --abbrev=0 --exclude='rolling-main' "$CURRENT_SHA" 2>/dev/null); then
    SECTION_TITLE="Commits since \`${PREVIOUS_TAG}\`"
    COMMITS="$(git log --reverse --format='- %s' "${PREVIOUS_TAG}..${CURRENT_SHA}")"
else
    SECTION_TITLE="Commits in repository history"
    COMMITS="$(git log --reverse --format='- %s' "$CURRENT_SHA")"
fi

if [ -z "$COMMITS" ]; then
    COMMITS="- No commits found for this release."
fi

cat > "$OUTPUT_FILE" <<EOF
Automated build from \`${CURRENT_SHA}\`.

- Branch: \`${BRANCH_NAME}\`
- Commit: \`${CURRENT_SHA}\`
- Built at: \`${BUILT_AT}\`
- Assets: \`MenuPlay-macos.zip\`, \`MenuPlay-macos.dmg\`

## ${SECTION_TITLE}

${COMMITS}

This build is unsigned and not notarized.
EOF
