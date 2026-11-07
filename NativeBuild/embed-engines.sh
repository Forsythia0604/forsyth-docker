#!/bin/sh
set -eu
task_source_root="${SRCROOT}/.."
task_contents="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}"
mkdir -p "${task_contents}/Helpers" "${task_contents}/Resources/WindowHelper"
/usr/bin/ditto "${task_source_root}/Engines/DockLock.app" "${task_contents}/Helpers/DockLock.app"
/usr/bin/ditto "${FORSYTH_WINDOW_HELPER}" "${task_contents}/Helpers/Dock 窗口助手.app"
/usr/bin/ditto "${BUILT_PRODUCTS_DIR}/DockerControlHost.app" "${task_contents}/Helpers/DockerControlHost.app"
/usr/bin/ditto "${BUILT_PRODUCTS_DIR}/DockerWatchdog" "${task_contents}/MacOS/DockerWatchdog"
/bin/cp "${task_source_root}/WindowHelper/window-layout.js" "${task_contents}/Resources/WindowHelper/window-layout.js"
