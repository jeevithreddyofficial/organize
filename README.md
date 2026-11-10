# Organize

A tiny macOS menu-bar app that automatically tiles your open windows into a grid on any desktop (Space).

- When windows open or close, it waits a moment for them to settle.
- If there are 2+ windows and they aren't already in a grid, it tiles them (4 windows become a 2x2).
- If they're already in a grid, it leaves them alone.
- Minimized, hidden and full-screen windows are ignored.
- Menu-bar options: toggle auto-organize, "Organize Now" (global hotkey **⌃⌥O**), open Accessibility settings.

## Build & run

```sh
./build.sh
open Organize.app
```

Requires the Xcode command-line tools (`swiftc`). On first launch, grant access under
System Settings → Privacy & Security → Accessibility (use **+** and pick `Organize.app`). No relaunch
is needed. The build signs the app with a stable identifier-based requirement, so the permission
survives rebuilds.

Tested on macOS 26 (Tahoe). It uses private macOS APIs, so future macOS releases may break it.

## Notes

Only re-tiles when the set of windows changes (not while you drag a window). Tiles on the main display only.
