#!/bin/bash
# Moves everything the app kept under its old name, "the-mind", to where
# Cortex looks for it. Run through `make migrate`, before the first
# `make install` of Cortex. Safe to run again: whatever is already moved is
# left alone.
#
#   ~/Library/Application Support/the-mind/the-mind.sqlite (+ -wal, -shm, Blobs/)
#     → ~/Library/Application Support/Cortex/Cortex.sqlite
#   ~/.config/the-mind/ (quick action TOML files) → ~/.config/cortex/
#   settings (UserDefaults <prefix>.TheMind) → <prefix>.Cortex
#   /Applications/the-mind.app → Trash
#
# The database key stays in the Keychain under the old service name; Cortex
# moves it on its first launch (macOS asks once, see the summary below).

set -euo pipefail

prefix=${1:?usage: $0 BUNDLE_ID_PREFIX}
old_id="$prefix.TheMind"
new_id="$prefix.Cortex"

support="$HOME/Library/Application Support"
old_data="$support/the-mind"
new_data="$support/Cortex"
config="${XDG_CONFIG_HOME:-$HOME/.config}"
old_config="$config/the-mind"
new_config="$config/cortex"
old_app="/Applications/the-mind.app"

# Check everything before moving anything.
for pair in "$old_data|$new_data" "$old_config|$new_config"; do
    old=${pair%|*}
    new=${pair#*|}
    if [ -e "$old" ] && [ -e "$new" ]; then
        echo "error: both $old and $new exist." >&2
        echo "If Cortex already started without migrating, it created an empty $new." >&2
        echo "Move $new aside (keep it until you have checked the result) and run make migrate again." >&2
        exit 1
    fi
done

# Neither app may hold the database open while it moves.
for name in the-mind Cortex; do
    if pkill -x "$name"; then
        echo "Quit the running $name."
        for _ in $(seq 20); do pgrep -x "$name" >/dev/null || break; sleep 0.5; done
        if pgrep -x "$name" >/dev/null; then
            echo "error: $name is still running. Quit it and run make migrate again." >&2
            exit 1
        fi
    fi
done

if [ -d "$old_data" ]; then
    mv "$old_data" "$new_data"
    for suffix in "" -wal -shm; do
        if [ -e "$new_data/the-mind.sqlite$suffix" ]; then
            mv "$new_data/the-mind.sqlite$suffix" "$new_data/Cortex.sqlite$suffix"
        fi
    done
    echo "Moved the database: $new_data/Cortex.sqlite"
else
    echo "No database at $old_data; nothing to move."
fi

if [ -d "$old_config" ]; then
    mv "$old_config" "$new_config"
    echo "Moved the quick action files: $new_config/actions"
fi

if defaults read "$old_id" >/dev/null 2>&1; then
    if defaults read "$new_id" >/dev/null 2>&1; then
        echo "Cortex already has settings ($new_id); left them as they are."
    else
        defaults export "$old_id" - | defaults import "$new_id" -
        defaults delete "$old_id"
        echo "Moved the settings: $old_id → $new_id"
    fi
fi

if [ -d "$old_app" ]; then
    trashed="$HOME/.Trash/the-mind.app"
    [ -e "$trashed" ] && trashed="$HOME/.Trash/the-mind $(date +%Y%m%d-%H%M%S).app"
    mv "$old_app" "$trashed"
    echo "Moved $old_app to the Trash."
fi

# The old entries in System Settings → Privacy & Security point at the
# trashed app. Cortex is a new app to macOS and asks for its own.
tccutil reset Accessibility "$old_id" >/dev/null 2>&1 || true
tccutil reset AppleEvents "$old_id" >/dev/null 2>&1 || true

echo
echo "Next: make install. Then, once:"
if security find-generic-password -s dev.jonaszell.the-mind -a database-key >/dev/null 2>&1; then
    echo "- Cortex moves the database key in the Keychain. macOS asks whether Cortex may"
    echo "  use \"dev.jonaszell.the-mind\": enter your login password and choose Always Allow."
fi
echo "- Grant Cortex Accessibility (the welcome window asks) and, for quick actions on"
echo "  Finder files, control of Finder when macOS asks."
echo "- If the-mind started at login: Cortex Settings → Launch at login."
