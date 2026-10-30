#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
bundle="$project_root/build/AgentDesk.app"
# Never overwrite a running executable. The agent performs normal app quit
# before invoking this script, as required by AGENTS.md.
running_executables="$(/bin/ps -axo comm=)"
while IFS= read -r running_executable; do
  if [[ "$running_executable" == "$bundle/Contents/MacOS/AgentDesk" ]]; then
    printf 'AgentDesk is still running. Quit it before rebuilding.\n' >&2
    exit 1
  fi
done <<< "$running_executables"
# The canvas page is built first so a frontend error never leaves a bundle
# without its UI. npm ci only runs when dependencies are missing.
if [[ ! -d "$project_root/canvas-web/node_modules" ]]; then
  npm --prefix "$project_root/canvas-web" ci
fi
npm --prefix "$project_root/canvas-web" run build
# Only this generated app bundle is replaced; Application Support is retained.
/bin/rm -rf -- "$bundle"
/usr/bin/swift build -c release --product AgentDesk
/usr/bin/swift build -c release --product agentdesk-files
binary_dir="$(/usr/bin/swift build -c release --show-bin-path)"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$binary_dir/AgentDesk" "$bundle/Contents/MacOS/AgentDesk"
# AgentDesk's files MCP server; the CLIs start it for folder reads.
cp "$binary_dir/agentdesk-files" "$bundle/Contents/MacOS/agentdesk-files"
cp "$project_root/Resources/Info.plist" "$bundle/Contents/Info.plist"
mkdir -p "$bundle/Contents/Resources/ProviderIcons"
cp "$project_root/Resources/ProviderIcons/"*.svg "$bundle/Contents/Resources/ProviderIcons/"
cp -R "$project_root/canvas-web/dist" "$bundle/Contents/Resources/Canvas"
/usr/bin/codesign --force --sign - "$bundle"
printf 'Built: %s\n' "$bundle"
