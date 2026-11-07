#!/system/bin/sh
# FJGuard 自愈钩子（安装时复制到 /data/adb/post-fs-data.d/，位于模块目录之外）
# 作用：模块目录被恶意删除时，从 /data/local 的副本重建；并执行开机修复

ENF=/data/local/fjguard_stash/.enabled
[ -f "$ENF" ] || exit 0
[ -f /data/adb/fjguard/DISABLED ] && exit 0

MOD=/data/adb/modules/fjguard
STASH=/data/local/fjguard_stash

# 1) 模块目录缺失 → 从 stash 重建
if [ ! -f "$MOD/module.prop" ] && [ -d "$STASH/module/bin" ]; then
    mkdir -p "$MOD" 2>/dev/null
    cp -rf "$STASH/module/"* "$MOD/" 2>/dev/null
    chmod 755 "$MOD/bin"/*.sh "$MOD/post-fs-data.sh" "$MOD/service.sh" "$MOD/uninstall.sh" 2>/dev/null
fi

# 2) 运行时副本 + 关键文件修复
if [ -f "$MOD/bin/common.sh" ]; then
    . "$MOD/bin/common.sh"
    fjg_init_dirs
    fjg_sync_rt "$MOD/bin"
    fjg_repair_missing
    fjg_repair_broken
    fjg_log hook post-fs-data "自愈钩子执行完成"
fi
exit 0
