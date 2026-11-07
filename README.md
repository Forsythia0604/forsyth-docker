# Docker · Forsyth

Docker is a native macOS app for organizing the Dock, grouping applications into stacks, keeping windows clear of the Dock, and quitting selected apps from Control Center. This repository preserves the project and its last local test build as a record of how it was made.

## Test build

[Version 1.0.0, build 1012](https://github.com/Forsythia0604/forsyth-docker/releases/tag/v1.0.0-test.1012) contains the original app bundle. It targets Apple silicon Macs running macOS 26 or later. The bundle retains its development signature and was not notarized for public distribution. It runs locally and does not require an account.

Open the app to configure it. Closing the settings window leaves Docker running; use the Docker menu bar icon or Control–Option–Command–D to reopen settings. Quit Docker to return to the native Dock.

## What it does

- **Organize apps.** Pin applications, show them only while running, or group them into named stacks. Set a cover icon, edit the member list, and reorder stacks. Hiding an icon leaves its app running.
- **Customize the Dock.** Resize it by dragging its edge, adjust the Liquid Glass material, and configure running indicators and notification badges. The application library opens the native macOS app list.
- **Keep windows clear.** Maximized and tiled windows leave room above the Dock. Manual moves and resizes remain under your control. The test window helper reacts to window events, and the custom Dock gets out of the way for native full screen.
- **Use shortcuts and previews.** Inspect supported apps' Dock actions and, where available, list their windows or Safari and Chrome tabs. macOS does not offer a public API for copying every other app's Dock menu, so coverage varies.
- **Quit apps safely.** Review which apps will be asked to quit or add the small **Quit Apps** control to Control Center. Apps can show their own save prompts. Docker waits for an app to exit before continuing and keeps apps on the exclusion list open.
- **Use the system Trash.** The Trash icon shows the current empty or full state. Emptying it requires confirmation.

Window management and access to other apps' menus use macOS Accessibility permissions. The app, its window helper, and the DockLock component may have separate permissions. The test build was exercised on one display; its multi-display rules were not fully tested on physical multi-display setups.

See the [development guide](DEVELOPMENT.md) for build and test instructions. The DockLock engine comes from [yihui-dev/docklock-yihui](https://github.com/yihui-dev/docklock-yihui) and retains its [MIT license and notices](ThirdParty/DockLock-LICENSE.txt).
