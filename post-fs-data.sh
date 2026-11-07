#!/system/bin/sh
# FJGuard 开机早期自愈：在 system_server 启动前把关键文件补回来
# 这是"格机后置死"的主防线：锁屏/包管理数据库缺失导致的无法解锁、开机失败，在此修复

MODDIR=${0%/*}
[ -d "$MODDIR/bin" ] || MODDIR=/data/adb/modules/fjguard
_BD="$MODDIR/bin/common.sh"
[ -f "$_BD" ] || _BD=/data/adb/fjguard/rt/common.sh
[ -f "$_BD" ] || _BD=/data/adb/modules/fjguard/bin/common.sh
[ -f "$_BD" ] || exit 0
. "$_BD"

[ -e "$FLAG_DISABLE" ] && exit 0

fjg_init_dirs

# 1) 运行时副本同步（含 chattr +i 自保护）
[ -d "$MODDIR/bin" ] && fjg_sync_rt "$MODDIR/bin"

# 2) 修复缺失 / 被写坏的关键文件
fjg_repair_missing
fjg_repair_broken

# 3) 基线过期（>12h）才刷新，避免每次开机都写盘
if [ -f "$RT/snapshot.sh" ]; then
    sh "$RT/snapshot.sh" --maybe >/dev/null 2>&1
elif [ -f "$MODDIR/bin/snapshot.sh" ]; then
    sh "$MODDIR/bin/snapshot.sh" --maybe >/dev/null 2>&1
fi

fjg_log boot post-fs-data "开机自愈完成"
exit 0
