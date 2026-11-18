#!/bin/bash
# 双击运行：把刚编译好的 build/SayFlow.app 装到 /Library/Input Methods（需要输入你的开机密码）
# 正式发给同事时用 DMG 拖拽安装，这个脚本只给开发者自己测试用。
cd "$(dirname "$0")" || exit 1
[ -d build/SayFlow.app ] || { echo "请先双击「一键编译并自查.command」"; read -r; exit 1; }
echo "将安装到 /Library/Input Methods/SayFlow.app，需要输入开机密码："
sudo rm -rf "/Library/Input Methods/SayFlow.app"
sudo ditto build/SayFlow.app "/Library/Input Methods/SayFlow.app"
killall SayFlow 2>/dev/null || true
echo
echo "已安装。第一次安装请：系统设置 → 键盘 → 输入法 → 编辑 → 加号 → 简体中文 → SayFlow。"
echo "列表里没有的话，注销重新登录一次。更新安装后切换一次输入法即可生效。"
