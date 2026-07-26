#!/bin/zsh
set -eu

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
dist_dir="${project_dir}/dist"
app_bundle="${dist_dir}/Caffeinate 管理器.app"
contents_dir="${app_bundle}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
build_work_dir="$(mktemp -d /private/tmp/caffeinate-monitor-build.XXXXXX)"
module_cache_dir="${build_work_dir}/module-cache"
icon_work_dir="${build_work_dir}/icon"

trap '/bin/rm -rf -- "${build_work_dir}"' EXIT

/bin/mkdir -p \
  "${dist_dir}" \
  "${macos_dir}" \
  "${resources_dir}" \
  "${module_cache_dir}" \
  "${icon_work_dir}"

macos_sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
machine_architecture="$(/usr/bin/uname -m)"
case "${machine_architecture}" in
  arm64|x86_64) ;;
  *)
    echo "不支持的处理器架构：${machine_architecture}" >&2
    exit 1
    ;;
esac
deployment_target="${machine_architecture}-apple-macosx13.0"
source_files=("${project_dir}"/Sources/*.swift)

/usr/bin/xcrun swiftc \
  -parse-as-library \
  -O \
  -whole-module-optimization \
  -sdk "${macos_sdk_path}" \
  -target "${deployment_target}" \
  -module-cache-path "${module_cache_dir}" \
  -framework SwiftUI \
  -framework AppKit \
  "${source_files[@]}" \
  -o "${macos_dir}/CaffeinateMonitor"

/bin/cp "${project_dir}/Resources/Info.plist" "${contents_dir}/Info.plist"

/usr/bin/xcrun swiftc \
  -parse-as-library \
  -O \
  -sdk "${macos_sdk_path}" \
  -target "${deployment_target}" \
  -module-cache-path "${module_cache_dir}" \
  -framework AppKit \
  "${project_dir}/Tools/GenerateIcon.swift" \
  -o "${build_work_dir}/GenerateIcon"

"${build_work_dir}/GenerateIcon" "${icon_work_dir}/AppIcon.iconset"
/usr/bin/iconutil \
  -c icns \
  "${icon_work_dir}/AppIcon.iconset" \
  -o "${resources_dir}/AppIcon.icns"

/usr/bin/plutil -lint "${contents_dir}/Info.plist"
/usr/bin/codesign \
  --force \
  --sign - \
  --timestamp=none \
  "${app_bundle}"
/usr/bin/codesign --verify --strict --verbose=2 "${app_bundle}"

echo "已构建：${app_bundle}"
