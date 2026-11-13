#!/bin/zsh
# Build Monitor Bar and monitorctl. Needs only the Command Line Tools (no Xcode).
#
#   ./build.sh            build both into build/ (the app) and bin/ (the command-line tool)
#   ./build.sh --run      also quit any running copy of the app and open the build/ copy
#                         (development only: don't keep it once the app is installed)
#   ./build.sh --install  also copy the app into ~/Applications and open that copy
#
# Nothing is replaced until the whole build has succeeded, so a failed build never leaves
# you without a working app or command-line tool.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

# Sign with the private "Monitor Bar Local Signing" certificate in the login keychain (made on
# 13 Nov 2026), so macOS permissions such as Accessibility survive rebuilds. Without it, fall
# back to ad hoc signing, which works but makes every build look like a new app to macOS.
IDENTITY="Monitor Bar Local Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then SIGN="$IDENTITY"; else SIGN="-"; fi

# The command-line tool: copy into bin/ in one atomic step.
mkdir -p bin
cp "$BIN/monitorctl" bin/.monitorctl.new
codesign --force --sign "$SIGN" bin/.monitorctl.new 2>/dev/null
mv -f bin/.monitorctl.new bin/monitorctl

# The app: assemble the .app bundle by hand, sign it ad hoc, then swap it in.
APP=build/MonitorBar.app
rm -rf "$APP.new"
mkdir -p "$APP.new/Contents/MacOS"
cp "$BIN/MonitorBar" "$APP.new/Contents/MacOS/MonitorBar"
cp Resources/Info.plist "$APP.new/Contents/Info.plist"
codesign --force --sign "$SIGN" "$APP.new" 2>/dev/null

MODE="${1:-}"
if [[ "$MODE" == "--run" || "$MODE" == "--install" ]]; then
    pkill -x MonitorBar 2>/dev/null && sleep 0.5 || true
fi
rm -rf "$APP"
mv "$APP.new" "$APP"
echo "Built: $PWD/$APP and $PWD/bin/monitorctl"

if [[ "$MODE" == "--install" ]]; then
    DEST="$HOME/Applications/MonitorBar.app"
    mkdir -p "$HOME/Applications"
    # Move rather than copy: two copies with the same identity confuse macOS's permission
    # records (Accessibility), so the installed copy must be the only one.
    rm -rf "$DEST.new"
    mv "$APP" "$DEST.new"
    rm -rf "$DEST"
    mv "$DEST.new" "$DEST"
    echo "Installed: $DEST"
    open "$DEST"
elif [[ "$MODE" == "--run" ]]; then
    open "$APP"
fi
