# Development

The source targets Apple silicon and macOS 26 or later. To build the app with its native Control Center extension, install full Xcode, XcodeGen and Python 3. The tests also use Node.js. The build defaults to `/Applications/Xcode.app`; set `DEVELOPER_DIR` to use a different Xcode installation without changing the system default.

Run these commands from the repository root:

```sh
./dev.sh          # Build and open the UI preview
./dev.sh build    # Build without launching
./dev.sh full     # Build and run with native Dock integration
./test.sh         # Run the regression checks
```

The preview uses separate bundle identifiers. It does not hide the native Dock, start the window helper, register global shortcuts, quit other apps, or write the normal app configuration. In full mode, the app takes over the Dock. Quit the existing instance before replacing a running build.

## Signing and the Control Center extension

`build.py` generates the project from `NativeBuild/project.yml`. The native Control Center action needs App Intents metadata from full Xcode and an Apple Development signature. The app and its provider must be signed by the same team. After adding your Apple account in Xcode, set:

```sh
export FORSYTH_DEVELOPMENT_TEAM=YOUR_TEAM_ID
```

Use `python3 build.py --help` for build options. Pass `--allow-provisioning-updates` if Xcode needs permission to prepare signing assets. An ad hoc build can be used for UI preview, but cannot run the native Control Center action.

The signed Control Center provider is embedded in the app. Because WidgetKit excludes a provider nested inside another app, Docker installs a copy for the active build under `~/Library/Application Support/DockerForsyth/ControlCenter/`. The provider can quit apps according to the saved rules without starting the custom Dock.

The `Engines/` directory retains the original signed DockLock engine and window helper. Re-signing them can require Accessibility authorization again. The build can reuse the window helper from an existing test bundle to preserve its signature.

## Local state and verification

App configuration lives under `~/Library/Application Support/DockerForsyth/`. The test and production apps shared configuration during local development and were run one at a time. The archive excludes that configuration, runtime logs and local build output.

The build 1012 window helper reacts to Accessibility window changes, workspace events, mouse releases and Dock layout changes. It coalesces bursts of events and limits follow-up scans while windows settle. A periodic connection check does not trigger a full scan. The app's runtime diagnostics can be used locally to check the scan count.

The regression suite covers configuration, edge protection, Trash state, window sizing and tiling, quit coordination, directory events and menu copying.
