# SuperDock

SuperDock is a native macOS menu-bar utility that shows live previews of an
application's windows when the pointer rests on its Dock icon. Clicking a
preview restores and focuses that exact window.

## Requirements

- macOS 14 or later
- Accessibility permission (required to inspect the Dock and focus windows)
- Screen Recording permission (required only for live thumbnails)
- Xcode 16 or later

## Run

1. Open `SuperDock.xcodeproj` in Xcode.
2. Select the **SuperDock** scheme and run it.
3. Use the menu-bar icon to grant Accessibility permission.
4. Hover over a running application's Dock icon for about 250 ms.

The first preview attempt may trigger the Screen Recording permission prompt.
After changing either privacy permission, restart SuperDock.

## Notes

- Minimized windows are included, but macOS may not provide a current image for
  them; SuperDock displays a placeholder until the window is restored.
- Full-screen windows in another Space can be focused, but their thumbnail may
  be unavailable until macOS exposes that Space to ScreenCaptureKit.
- This implementation uses public Accessibility and ScreenCaptureKit APIs. It
  does not inject code into or modify the system Dock.

