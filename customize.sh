#!/system/bin/sh
# FJGuard 安装脚本（由 Magisk / KernelSU / APatch 在刷入时执行）

SKIPUNZIP=0

# 输出函数：各管理器都提供 ui_print；缺失时退回 echo
_ui() { if command -v ui_print >/dev/null 2>&1; then ui_print "$1"; else echo "$1"; fi }

# root 管理器识别（环境变量优先，目录判断兜底）
if [ -n "${MAGISK_VER:-}" ] || command -v magisk >/dev/null 2>&1; then
    _RM="Magisk"
elif [ -n "${KSU:-}" ] || [ -d /data/adb/ksu ]; then
    _RM="KernelSU"
elif [ -n "${APATCH:-}" ] || [ -d /data/adb/ap ]; then
    _RM="APatch"
else
    _RM="未知"
fi

_ui "- 安装 FJGuard 防格机模块（检测到 root 管理器: $_RM）"

_BD="$MODPATH/bin/common.sh"
if [ ! -f "$_BD" ]; then
    _ui "! 压缩包结构异常：缺少 bin/common.sh"
    exit 1
fi
. "$_BD"

fjg_init_dirs

# 1) 配置（已有配置则保留用户改动）
if [ ! -f "$CFG" ]; then
    cp -f "$MODPATH/config/guard.conf" "$CFG" 2>/dev/null
fi

# 2) 灾后自愈副本：整个模块 + 基线放在模块目录之外
rm -rf "$STASH/module" 2>/dev/null
mkdir -p "$STASH/module" 2>/dev/null
for _item in bin config hook META-INF module.prop post-fs-data.sh service.sh uninstall.sh README.md; do
    [ -e "$MODPATH/$_item" ] && cp -rf "$MODPATH/$_item" "$STASH/module/" 2>/dev/null
done
: > "$STASH/.enabled"
chmod 700 "$STASH" 2>/dev/null

# 3) 全局钩子（仅在 Magisk 下有效：Magisk 会执行 /data/adb/{post-fs-data.d,service.d}；
#    KernelSU/APatch 不保证执行这两个目录，故不安装，核心防护不依赖它们）
if [ "$_RM" = "Magisk" ]; then
    for _d in /data/adb/post-fs-data.d /data/adb/service.d; do
        mkdir -p "$_d" 2>/dev/null
    done
    cp -f "$MODPATH/hook/post-fs-data.sh" /data/adb/post-fs-data.d/fjguard_hook.sh 2>/dev/null
    chmod 755 /data/adb/post-fs-data.d/fjguard_hook.sh 2>/dev/null
    cp -f "$MODPATH/hook/service.sh" /data/adb/service.d/fjguard_hook.sh 2>/dev/null
    chmod 755 /data/adb/service.d/fjguard_hook.sh 2>/dev/null
    _ui "- 已安装 Magisk 自愈钩子（模块目录被删可重建）"
else
    _ui "- $_RM 环境：跳过全局钩子，防护由模块自身 post-fs-data.sh / service.sh 承担"
fi

# 4) 建立基线快照
chmod 755 "$MODPATH/bin"/*.sh 2>/dev/null
sh "$MODPATH/bin/snapshot.sh" --init >/dev/null 2>&1
_ui "- 基线快照: $(wc -l < "$INDEX" 2>/dev/null || echo 0) 项"

# 5) 运行时副本 + 自保护
fjg_sync_rt "$MODPATH/bin"

# 6) 立即启动守护（不必等重启）
if [ -f "$RT/supervisor.sh" ]; then
    nohup "$RT/supervisor.sh" A >>"$LOGDIR/supervisor.log" 2>&1 &
    sleep 1
    nohup "$RT/supervisor.sh" B >>"$LOGDIR/supervisor.log" 2>&1 &
    sleep 2
fi

fjg_log install done "安装完成 $FJG_VERSION（$_RM）"
_ui "- 防护已启动；reboot 后开机自愈同样生效"
_ui "- 管理命令: su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh status'"
exit 0
