#!/bin/zsh
set -euo pipefail
package_dir="${0:A:h}"
app_name='蓝牙鼠标保活.app'
source_app="$package_dir/$app_name"
target_app="$HOME/Applications/$app_name"
fail() { print -u2 -- "$1"; read -r '?按回车关闭窗口…'; exit 1; }
[[ -d "$source_app" ]] || fail '请完整解压后再运行安装脚本。'
/usr/bin/codesign --verify --strict "$source_app" || fail '应用签名校验失败，请重新下载。'
/bin/mkdir -p "$HOME/Applications"
if [[ -e "$target_app" ]]; then
    /usr/bin/diff -qr "$source_app" "$target_app" >/dev/null || fail '同名位置已有不同内容，请先退出并备份旧应用。'
else
    /usr/bin/ditto --norsrc --noextattr "$source_app" "$target_app"
fi
/usr/bin/codesign --verify --strict "$target_app" || fail '安装后的应用校验失败。'
/usr/bin/open -g "$target_app" || fail '应用未能打开，请按系统安全提示处理。'
print -- '已安装。请从菜单栏选择鼠标，再按需要授权和启用“登录时启动”。'
print -- '若此前使用旧版，请先退出旧版并关闭其登录启动。'
read -r '?按回车关闭窗口…'
