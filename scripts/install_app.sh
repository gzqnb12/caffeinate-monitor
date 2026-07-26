#!/bin/zsh
set -eu

script_dir="${0:A:h}"
project_dir="${script_dir:h}"
source_app="${project_dir}/dist/Caffeinate 管理器.app"
user_apps_dir="${HOME}/Applications"
installed_app="${user_apps_dir}/Caffeinate 管理器.app"

"${project_dir}/scripts/build_app.sh"
/bin/mkdir -p "${user_apps_dir}"
/usr/bin/ditto "${source_app}" "${installed_app}"
/usr/bin/codesign --verify --strict --verbose=2 "${installed_app}"

echo "已安装：${installed_app}"
