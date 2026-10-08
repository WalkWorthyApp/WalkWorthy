#!/bin/bash
set -euo pipefail

# Host-only behavioral harness, not an iOS test target or Firebase integration test.
test_dir="$(cd "$(dirname "$0")" && pwd)"
app_dir="$test_dir/../../WalkWorthy"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/walkworthy-account-state.XXXXXX")"
trap 'rm -rf "$build_dir"' EXIT
swift_compiler="$(xcrun --find swiftc)"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"

for sdk_stub in FirebaseAnalytics FirebaseCrashlytics; do
  "$swift_compiler" -sdk "$sdk_path" -emit-module -emit-library \
    -module-cache-path "$build_dir/module-cache" \
    -module-name "$sdk_stub" "$test_dir/$sdk_stub.swift" \
    -emit-module-path "$build_dir/$sdk_stub.swiftmodule" \
    -o "$build_dir/lib$sdk_stub.dylib"
done

"$swift_compiler" -sdk "$sdk_path" -swift-version 5 -default-isolation MainActor \
  -module-cache-path "$build_dir/module-cache" \
  -parse-as-library -I "$build_dir" -L "$build_dir" \
  -lFirebaseAnalytics -lFirebaseCrashlytics -Xlinker -rpath -Xlinker "$build_dir" \
  "$app_dir/Auth/AuthSessionIdentity.swift" "$app_dir/App/AppState.swift" \
  "$app_dir/App/Config.swift" "$app_dir/Networking/APIError.swift" \
  "$app_dir/Models/EncouragementModels.swift" "$app_dir/Models/MoodModels.swift" \
  "$app_dir/Models/JournalModels.swift" \
  "$test_dir/Dependencies.swift" "$test_dir/Tests.swift" \
  -o "$build_dir/account-state-tests"
"$build_dir/account-state-tests"
