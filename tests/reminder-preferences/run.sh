#!/bin/bash
set -euo pipefail

test_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$test_dir/../.." && pwd)"
source_root="${1:-$repo_root}"
test_package="$(mktemp -d "${TMPDIR:-/tmp}/walkworthy-reminders.XXXXXX")"
trap 'rm -rf "$test_package"' EXIT

mkdir -p "$test_package/Sources/ReminderBoundary" "$test_package/Tests/ReminderBoundaryTests"
cat > "$test_package/Package.swift" <<'SWIFT'
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ReminderBoundary",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "ReminderBoundary"),
        .testTarget(name: "ReminderBoundaryTests", dependencies: ["ReminderBoundary"])
    ]
)
SWIFT

python3 "$test_dir/extract-boundaries.py" "$source_root" "$test_package/Sources/ReminderBoundary"
cp "$test_dir/ReminderPreferencesTests.swift" "$test_package/Tests/ReminderBoundaryTests/"

CLANG_MODULE_CACHE_PATH="$test_package/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$test_package/module-cache" \
xcrun swift test --package-path "$test_package" --disable-sandbox \
    --cache-path "$test_package/cache" --config-path "$test_package/config" \
    --security-path "$test_package/security"
