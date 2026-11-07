#!/usr/bin/env python3
"""Build Docker and its native Control Center extension with full Xcode."""
from pathlib import Path
import argparse
import os
import plistlib
import shutil
import subprocess
import tempfile
import re
import json

ROOT = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
parser.add_argument("--development", action="store_true")
parser.add_argument("--preview", action="store_true", help="Use a separate identity for UI previews")
parser.add_argument("--reuse-window-helper", type=Path)
parser.add_argument("--team", default=os.environ.get("FORSYTH_DEVELOPMENT_TEAM"),
                    help="Apple development team used by the app and native control")
parser.add_argument("--allow-ad-hoc", action="store_true",
                    help="Compile a UI-only debug build; native App Intents cannot execute")
parser.add_argument("--allow-provisioning-updates", action="store_true")
args = parser.parse_args()
if args.team and not re.fullmatch(r"[A-Z0-9]{10}", args.team):
    parser.error("An Apple development team ID must contain 10 uppercase letters or digits.")
if not args.team and not args.allow_ad_hoc and not args.preview:
    parser.error("Native controls require Apple development signing. Set --team or FORSYTH_DEVELOPMENT_TEAM.")
destination = args.destination.resolve()
if destination.suffix != ".app":
    parser.error("Destination must end in .app")
running_paths = subprocess.check_output(["/bin/ps", "-axo", "comm="], text=True).splitlines()
if str(destination / "Contents/MacOS/Docker") in (p.strip() for p in running_paths):
    raise SystemExit("Quit the destination Docker normally before replacing it.")

env = os.environ.copy()
developer = Path(env.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
if not (developer / "usr/bin/xcodebuild").is_file():
    raise SystemExit("Full Xcode is required for App Intents metadata. Install Xcode from Apple's App Store.")
env["DEVELOPER_DIR"] = str(developer)
subprocess.run(["/usr/bin/xcrun", "--find", "appintentsmetadataprocessor"], env=env, check=True,
               stdout=subprocess.DEVNULL)
xcodegen = shutil.which("xcodegen") or "/opt/homebrew/bin/xcodegen"
cache = ROOT / ".build" / ("native-preview" if args.preview else "native-testing" if args.development else "native-release")
inputs = cache / "inputs"
inputs.mkdir(parents=True, exist_ok=True)

with (ROOT / "Resources/Info.plist").open("rb") as handle:
    main_info = plistlib.load(handle)
main_info["ForsythDevelopmentBuild"] = args.development
main_info["ForsythInterfacePreview"] = args.preview
if args.development:
    main_info["CFBundleDisplayName"] = "Docker 测试版"
if args.preview:
    main_info["CFBundleIdentifier"] = "local.forsyth.docker.preview"
    main_info["CFBundleDisplayName"] = "Docker 界面预览"
if args.development:
    # WidgetKit uses the bundle build to distinguish updates. Keep development
    # builds increasing even when the delivery is staged in another directory.
    versions = [int(main_info["CFBundleVersion"])]
    prior_infos = [inputs / "MainInfo.plist", destination / "Contents/Info.plist"]
    if not args.preview:
        prior_infos.append(ROOT / "../../outputs/测试版/Docker.app/Contents/Info.plist")
    for previous in prior_infos:
        try:
            value = plistlib.loads(previous.read_bytes())
            if value.get("CFBundleIdentifier") == main_info["CFBundleIdentifier"]:
                versions.append(int(value["CFBundleVersion"]))
        except (OSError, ValueError, KeyError):
            pass
    main_info["CFBundleVersion"] = str(max(versions) + 1)
with (inputs / "MainInfo.plist").open("wb") as handle:
    plistlib.dump(main_info, handle)
with (ROOT / "Controls/Info.plist").open("rb") as handle:
    control_info = plistlib.load(handle)
host_id = (main_info["CFBundleIdentifier"] + ".controlhost" if args.preview else
           "local.forsyth.docker.controlhost" + (".testing" if args.development else ""))
control_id = host_id + ".controls"
control_info["CFBundleIdentifier"] = control_id
control_info["CFBundleVersion"] = main_info["CFBundleVersion"]
with (inputs / "ControlsInfo.plist").open("wb") as handle:
    plistlib.dump(control_info, handle)
with (ROOT / "Controls/HostInfo.plist").open("rb") as handle:
    host_info = plistlib.load(handle)
host_info["CFBundleIdentifier"] = host_id
host_info["CFBundleVersion"] = main_info["CFBundleVersion"]
host_info["ForsythDevelopmentBuild"] = args.development
host_info["ForsythInterfacePreview"] = args.preview
with (inputs / "ControlHostInfo.plist").open("wb") as handle:
    plistlib.dump(host_info, handle)

helper = args.reuse_window_helper
if helper is None:
    helper = (ROOT / "../../outputs/测试版/Docker.app/Contents/Helpers/Dock 窗口助手.app"
              if args.development else ROOT / "Engines/Dock 窗口助手.app")
helper = helper.resolve()
with (helper / "Contents/Info.plist").open("rb") as handle:
    helper_info = plistlib.load(handle)
expected_id = "local.codex.dock-window-helper" + (".testing" if args.development else "")
if helper_info.get("CFBundleIdentifier") != expected_id:
    raise SystemExit("Use --reuse-window-helper with the trusted helper for this build channel.")
subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(helper)], check=True)
subprocess.run([xcodegen, "generate", "--spec", str(ROOT / "NativeBuild/project.yml"),
                "--project", str(ROOT / "NativeBuild")], check=True, env=env)
product = cache / "DerivedData/Build/Products/Release/Docker.app"
if product.exists():
    # Start with an empty application wrapper when embedded targets change.
    # Keep the previous product recoverable; source and compiler caches remain.
    previous_product = Path(tempfile.mkdtemp(prefix="native-product-previous-", dir=ROOT / ".build"))
    product.rename(previous_product / "Docker.app.disabled")
build = ["/usr/bin/xcrun", "xcodebuild", "-project", str(ROOT / "NativeBuild/Docker.xcodeproj"),
                "-scheme", "Docker", "-configuration", "Release", "-derivedDataPath", str(cache / "DerivedData"),
                "-destination", "platform=macOS,arch=arm64", "ARCHS=arm64", "ONLY_ACTIVE_ARCH=YES",
                "FORSYTH_INPUT_DIR=" + str(inputs), "FORSYTH_WINDOW_HELPER=" + str(helper),
                "FORSYTH_CONTROLS_BUNDLE_ID=" + control_id,
                "FORSYTH_CONTROL_HOST_BUNDLE_ID=" + host_id,
                "FORSYTH_MAIN_BUNDLE_ID=" + main_info["CFBundleIdentifier"]]
if args.team:
    build += ["CODE_SIGN_STYLE=Automatic", "CODE_SIGN_IDENTITY=Apple Development", "DEVELOPMENT_TEAM=" + args.team]
if args.allow_provisioning_updates:
    build += ["-allowProvisioningUpdates"]
subprocess.run(build + ["build"], check=True, env=env)
host = product / "Contents/Helpers/DockerControlHost.app"
extension = host / "Contents/PlugIns/DockerControls.appex"
for bundle in [host, extension]:
    metadata = bundle / "Contents/Resources/Metadata.appintents"
    if not metadata.is_dir() or not any(metadata.iterdir()):
        raise SystemExit("Missing App Intents metadata in " + str(bundle))
    actions = json.loads((metadata / "extract.actionsdata").read_text()).get("actions", {})
    if actions.get("DockerQuitControlIntent", {}).get("identifier") != "DockerQuitControlIntent":
        raise SystemExit("Missing quit action in App Intents metadata for " + str(bundle))
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(product)], check=True)
if args.team:
    for bundle in [product, host, extension]:
        signed = subprocess.check_output(["/usr/bin/codesign", "-dv", str(bundle)], stderr=subprocess.STDOUT, text=True)
        if "TeamIdentifier=" + args.team not in signed:
            raise SystemExit("Native controls require matching Apple team signatures.")
# Xcode registers intermediate products automatically. Keep those copies out of
# extension discovery, so Control Center resolves the installed test app.
lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
host_product = product.parent / "DockerControlHost.app"
for intermediate in [host, host_product]:
    subprocess.run(["/usr/bin/pluginkit", "-r", str(intermediate / "Contents/PlugIns/DockerControls.appex")],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([lsregister, "-u", str(intermediate)], check=True)
subprocess.run([lsregister, "-u", str(product)], check=True)
if destination.exists():
    with (destination / "Contents/Info.plist").open("rb") as handle:
        old_info = plistlib.load(handle)
    if old_info.get("CFBundleIdentifier") != main_info["CFBundleIdentifier"]:
        raise SystemExit("Refusing to replace an unrelated application.")
destination.parent.mkdir(parents=True, exist_ok=True)
stage = Path(tempfile.mkdtemp(prefix="native-delivery-", dir=ROOT / ".build"))
subprocess.run(["/usr/bin/ditto", str(product), str(stage / "Docker.app")], check=True)
if destination.exists():
    destination.rename(stage / "previous.app.disabled")
shutil.move(str(stage / "Docker.app"), str(destination))
print(destination)
