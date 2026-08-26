#!/bin/zsh
set -eu

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
test_work_dir="$(mktemp -d /private/tmp/caffeinate-monitor-tests.XXXXXX)"
module_cache_dir="${test_work_dir}/module-cache"

trap '/bin/rm -rf -- "${test_work_dir}"' EXIT
/bin/mkdir -p "${module_cache_dir}"

macos_sdk_path="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
machine_architecture="$(/usr/bin/uname -m)"
deployment_target="${machine_architecture}-apple-macosx13.0"

/usr/bin/xcrun swiftc \
  -parse-as-library \
  -sdk "${macos_sdk_path}" \
  -target "${deployment_target}" \
  -module-cache-path "${module_cache_dir}" \
  "${project_dir}/Sources/Models.swift" \
  "${project_dir}/Sources/SystemScanner.swift" \
  "${project_dir}/Tests/RedactionTests.swift" \
  -o "${test_work_dir}/RedactionTests"

"${test_work_dir}/RedactionTests"
