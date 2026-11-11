#!/bin/bash
# Compiles and runs the PushPromptStore plain-script tests with swiftc only (no xcodebuild, no simulator).
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
out="$(mktemp -d)"
cp "$here/push_prompt_store_tests.swift" "$out/main.swift"   # top-level code requires main.swift
swiftc -o "$out/push_prompt_tests" "$here/../FellowScript/Onboarding/PushPromptStore.swift" "$out/main.swift"
"$out/push_prompt_tests"
