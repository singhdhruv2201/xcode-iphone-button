#!/bin/sh
# Copies the tool and stores device settings outside the checkout.
set -eu
umask 077

if [ "$#" -ne 0 ]; then
    printf '%s\n' 'Usage: sh install.sh (interactive; no sudo required)' >&2
    exit 2
fi
source_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
install_dir=${XCODE_IPHONE_BUTTON_HOME:-"$HOME/Library/Application Support/Xcode iPhone Button"}
case "$install_dir" in
    /*) ;;
    *) printf '%s\n' 'Installation directory must be an absolute path.' >&2; exit 2 ;;
esac
# Device settings must not land inside the source checkout.
mkdir -p "$install_dir"
install_dir=$(CDPATH= cd -- "$install_dir" && pwd -P)
case "$install_dir/" in
    "$source_dir/"*) printf '%s\n' 'Choose an installation directory outside the source checkout.' >&2; exit 2 ;;
esac

printf '%s\n' 'In Xcode > Window > Devices and Simulators, select your paired iPhone.'
printf '%s' 'Exact device name (including punctuation): '
IFS= read -r phone_name
printf '%s' 'Device Identifier from Xcode (not the CoreDevice UUID): '
IFS= read -r phone_id
if [ -z "$phone_name" ] || [ -z "$phone_id" ]; then
    printf '%s\n' 'Both values are required. Nothing was installed.' >&2
    exit 2
fi
case "$phone_id" in
    *[!a-zA-Z0-9-]*) printf '%s\n' 'The device identifier must contain only letters, digits, and hyphens.' >&2; exit 2 ;;
esac

mkdir -p "$install_dir/config"
chmod 700 "$install_dir" "$install_dir/config"
cp "$source_dir/run.sh" "$install_dir/run.sh"
cp "$source_dir/run-xcode.applescript" "$install_dir/run-xcode.applescript"
printf '%s\n' "$phone_name" > "$install_dir/config/device-name"
printf '%s\n' "$phone_id" > "$install_dir/config/device-id"
chmod 600 "$install_dir/config/device-name" "$install_dir/config/device-id"
chmod 700 "$install_dir/run.sh"
chmod 600 "$install_dir/run-xcode.applescript"
printf '%s\n' 'Installed. Device configuration stays on this Mac, outside the checkout.'
printf '%s\n' 'For the default installation, use this in Shortcuts > Run Script Over SSH:'
printf '%s\n' '/bin/sh "$HOME/Library/Application Support/Xcode iPhone Button/run.sh"'
