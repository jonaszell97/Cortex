#!/bin/bash
# Checks the module boundaries of docs/ARCHITECTURE.md ("Modules talking to each
# other" and "Repository layout"):
#   1. every folder in Cortex/Modules has its <Name>Module.swift;
#   2. App/ and Host/ name no type declared under Modules/ (App/ModuleList.swift
#      is the one place that lists the modules);
#   3. a module names another module's types only if they are declared in that
#      module's <Name>API.swift.
# Types are the top-level, non-private declarations; comments are ignored.
# Run by `make test-app`; exits non-zero and lists each crossing otherwise.

set -u
cd "$(dirname "$0")/.." || exit 2

modules=Cortex/Modules
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0

# The top-level types declared in the given files, one per line.
declared_types() {
    sed -nE 's/^(@[A-Za-z]+ )*((public|internal|final|nonisolated) )*(class|struct|enum|protocol|actor|typealias) ([A-Z][A-Za-z0-9_]*).*/\5/p' "$@" |
        sort -u
}

# Lines of the files that name one of the types in $1, as file:line: code.
crossings() {
    local names=$1
    shift
    [ -s "$names" ] || return 0
    local file
    for file in "$@"; do
        sed 's://.*$::' "$file" | grep -nwF -f "$names" | sed "s|^|$file:|"
    done
}

for folder in "$modules"/*/; do
    name=$(basename "$folder")
    if [ ! -f "$folder$name""Module.swift" ]; then
        echo "error: $folder has no ${name}Module.swift"
        failed=1
    fi
done

# 2. The host and the app.
declared_types $(find "$modules" -name '*.swift') > "$work/all"
host_files=$(find Cortex/Host Cortex/App -name '*.swift' ! -path Cortex/App/ModuleList.swift | sort)
found=$(crossings "$work/all" $host_files)
if [ -n "$found" ]; then
    echo "error: App/ and Host/ name types of modules (only App/ModuleList.swift may):"
    echo "$found"
    failed=1
fi

# 3. Between modules.
for folder in "$modules"/*/; do
    name=$(basename "$folder")
    internal=$(find "$folder" -name '*.swift' ! -name "${name}API.swift")
    [ -n "$internal" ] || continue
    declared_types $internal > "$work/$name"
    others=$(find "$modules" -name '*.swift' ! -path "$folder*" | sort)
    found=$(crossings "$work/$name" $others)
    if [ -n "$found" ]; then
        echo "error: these name types of $name outside its ${name}API.swift:"
        echo "$found"
        failed=1
    fi
done

[ "$failed" -eq 0 ] && echo "Module boundaries OK."
exit "$failed"
