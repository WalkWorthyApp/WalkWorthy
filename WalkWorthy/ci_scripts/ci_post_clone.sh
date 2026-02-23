#!/bin/bash
# ci_post_clone.sh
#
# Xcode Cloud post-clone script.
# Decodes the GOOGLE_SERVICE_INFO_B64 environment variable (set as a secret
# in App Store Connect) and writes GoogleService-Info.plist to the app target
# directory so Firebase can initialize correctly.
#
# Xcode Cloud sets CI_PRIMARY_REPOSITORY_PATH to the repo root.
# This script is located at: WalkWorthy/ci_scripts/ci_post_clone.sh
# The plist must land at:    WalkWorthy/WalkWorthy/GoogleService-Info.plist

set -euo pipefail

PLIST_DIR="${CI_PRIMARY_REPOSITORY_PATH}/WalkWorthy/WalkWorthy"
PLIST_PATH="${PLIST_DIR}/GoogleService-Info.plist"

echo "--- ci_post_clone: Injecting GoogleService-Info.plist ---"

# 1. Verify the environment variable is set
if [ -z "${GOOGLE_SERVICE_INFO_B64:-}" ]; then
    echo "ERROR: GOOGLE_SERVICE_INFO_B64 environment variable is not set."
    echo "Configure it as a secret in App Store Connect > Xcode Cloud > Workflow > Environment Variables."
    exit 1
fi

# 2. Verify the target directory exists
if [ ! -d "${PLIST_DIR}" ]; then
    echo "ERROR: Target directory does not exist: ${PLIST_DIR}"
    exit 1
fi

# 3. Decode and write the plist
echo "${GOOGLE_SERVICE_INFO_B64}" | base64 --decode > "${PLIST_PATH}"

# 4. Validate the output is a valid plist
if ! plutil -lint "${PLIST_PATH}" > /dev/null 2>&1; then
    echo "ERROR: Decoded file is not a valid plist. Check your Base64 encoding."
    rm -f "${PLIST_PATH}"
    exit 1
fi

echo "SUCCESS: GoogleService-Info.plist written to ${PLIST_PATH}"
echo "--- ci_post_clone: Done ---"
