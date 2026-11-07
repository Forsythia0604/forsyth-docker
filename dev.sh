#!/bin/zsh
set -euo pipefail
task_root="${0:A:h}"
task_mode="${1:-preview}"
case "$task_mode" in
  preview|full|build) ;;
  *) print -u2 '用法：./dev.sh [preview|full|build]'; exit 2 ;;
esac
task_app="$task_root/.build/dev/Docker.app"
if [[ "$task_mode" != preview && -d "$task_root/../../outputs/测试版" ]]; then
  task_app="$task_root/../../outputs/测试版/Docker.app"
fi
task_build_flags=(--development)
if [[ "$task_mode" == preview ]]; then task_build_flags+=(--preview); fi
python3 "$task_root/build.py" "$task_app" "${task_build_flags[@]}"
if [[ "$task_mode" == build ]]; then exit 0; fi
if [[ "$task_mode" == preview ]]; then
  /usr/bin/open -n "$task_app" --args --preview --profile "$task_root/.build/preview-profile"
else
  /usr/bin/open -n "$task_app" --args --replace-running
fi
