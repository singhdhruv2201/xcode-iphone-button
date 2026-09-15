#!/bin/sh
set -eu
tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ ! -s "$tool_dir/config/device-name" ] || [ ! -s "$tool_dir/config/device-id" ]; then
    printf '%s\n' 'Device configuration is missing. Run sh install.sh, then use the installed run.sh.' >&2
    exit 2
fi
phone_name=$(cat "$tool_dir/config/device-name")
phone_id=$(cat "$tool_dir/config/device-id")
case "$phone_id" in
    ''|*[!a-zA-Z0-9-]*) printf '%s\n' 'Invalid device identifier. Run the installer again.' >&2; exit 2 ;;
esac
# Arguments are data, never interpolated into AppleScript or evaluated as shell code.
exec /usr/bin/osascript "$tool_dir/run-xcode.applescript" "$phone_name" "$phone_id"
