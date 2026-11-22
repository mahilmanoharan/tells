#!/usr/bin/env bash
# DEFAULT: D-055 (all steps run, logs in .build/test-logs, --tsan skips the iOS build)
# Usage: scripts/test.sh [--tsan]
set -uo pipefail
cd "$(dirname "$0")/.."

tsan=0
case "${1:-}" in
  "") ;;
  --tsan) tsan=1 ;;
  *) echo "Usage: scripts/test.sh [--tsan]" >&2; exit 2 ;;
esac

log_dir=.build/test-logs
mkdir -p "$log_dir"
failed=()

run_step() {
  local name=$1; shift
  local log="$log_dir/${name// /_}.log"
  if "$@" >"$log" 2>&1; then
    echo "PASS  $name"
  else
    echo "FAIL  $name (full log: $log)"
    tail -n 30 "$log"
    failed+=("$name")
  fi
}

swift_flags=()
xcode_flags=()
if [ "$tsan" = 1 ]; then
  swift_flags=(--sanitize=thread)
  xcode_flags=(-enableThreadSanitizer YES)
fi

run_step "xcodegen" xcodegen generate
run_step "TellsCore tests" swift test --package-path TellsCore ${swift_flags[@]+"${swift_flags[@]}"}
run_step "TellsMac tests" swift test --package-path TellsMac ${swift_flags[@]+"${swift_flags[@]}"}
run_step "Tells app tests" xcodebuild test -project Tells.xcodeproj -scheme Tells \
  -destination 'platform=macOS' ${xcode_flags[@]+"${xcode_flags[@]}"}
if [ "$tsan" = 1 ]; then
  echo "SKIP  TellsCore iOS build (not run with --tsan)"
else
  run_step "TellsCore iOS build" bash -c \
    "cd TellsCore && xcodebuild build -scheme TellsCore -destination 'generic/platform=iOS'"
fi

if [ "${#failed[@]}" -eq 0 ]; then
  echo "PASS"
else
  names=$(IFS=,; echo "${failed[*]}")
  echo "FAIL ${#failed[@]} failed step(s): ${names//,/, }"
  exit 1
fi
