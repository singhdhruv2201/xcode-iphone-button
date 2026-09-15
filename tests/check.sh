#!/bin/sh
set -eu
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
scratch_dir=$(mktemp -d)
trap 'rm -rf "$scratch_dir"' EXIT HUP INT TERM
for script in install.sh run.sh tests/check.sh; do
    /bin/sh -n "$repo_dir/$script"
done
/usr/bin/osacompile -o "$scratch_dir/check.scpt" "$repo_dir/run-xcode.applescript"

# Synthetic name deliberately contains shell metacharacters; it must remain data.
example_name='Example Phone $(touch SHOULD_NOT_EXIST)'
example_id='TEST-DEVICE-ID'
printf '%s\n%s\n' "$example_name" "$example_id" |
    XCODE_IPHONE_BUTTON_HOME="$scratch_dir/install with spaces" /bin/sh "$repo_dir/install.sh" > "$scratch_dir/install-output"
test "$(cat "$scratch_dir/install with spaces/config/device-name")" = "$example_name"
test "$(cat "$scratch_dir/install with spaces/config/device-id")" = "$example_id"
test "$(stat -f '%Lp' "$scratch_dir/install with spaces/config/device-id")" = 600
test "$(stat -f '%Lp' "$scratch_dir/install with spaces/config")" = 700
cmp "$repo_dir/run-xcode.applescript" "$scratch_dir/install with spaces/run-xcode.applescript"
if /bin/sh "$repo_dir/run.sh" > "$scratch_dir/missing" 2>&1; then
    printf '%s\n' 'Expected missing configuration to fail.' >&2; exit 1
fi
grep -q 'configuration is missing' "$scratch_dir/missing"
if printf 'Example Phone\ninvalid,id\n' |
    XCODE_IPHONE_BUTTON_HOME="$scratch_dir/invalid" /bin/sh "$repo_dir/install.sh" > "$scratch_dir/invalid-output" 2>&1; then
    printf '%s\n' 'Expected invalid identifier to fail.' >&2; exit 1
fi
test ! -e "$scratch_dir/invalid/run.sh"
printf '%s\n' 'Passed: shell syntax, AppleScript compile, private installation, literal input, missing configuration, and invalid identifier.'
