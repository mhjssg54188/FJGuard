#!/system/bin/sh
# FJGuard 卸载：停守护 → 解 immutable → 清钩子与副本
# 注意：/sdcard/FJGuard 下的备份不删除，便于日后复查

MODDIR=${0%/*}
_BD="$MODDIR/bin/common.sh"
[ -f "$_BD" ] || _BD=/data/adb/fjguard/rt/common.sh
if [ -f "$_BD" ]; then . "$_BD"; fi

STASH=/data/local/fjguard_stash
RUNDIR=/data/adb/fjguard/run
STATE=/data/adb/fjguard

# 1) 停止守护
for _n in supervisor_A supervisor_B procguard watcher integrity; do
    _p=$(cat "$RUNDIR/$_n.pid" 2>/dev/null)
    [ -n "$_p" ] && kill -KILL "$_p" 2>/dev/null
done
for _d in /proc/[0-9]*; do
    _p=${_d#/proc/}
    [ -r "$_d/cmdline" ] || continue
    if grep -qa 'fjguard/rt/' "$_d/cmdline" 2>/dev/null; then
        kill -KILL "$_p" 2>/dev/null
    fi
done

# 2) 解除 immutable
if [ -d "$STATE" ]; then
    for _f in "$STATE"/rt/*.sh; do [ -f "$_f" ] && chattr -i "$_f" 2>/dev/null; done
    if [ -d "$STATE/baseline" ]; then
        find "$STATE/baseline" -type f 2>/dev/null | while IFS= read -r _f; do
            chattr -i "$_f" 2>/dev/null
        done
    fi
fi

# 3) 移除全局钩子与自愈标记（避免卸载后被"复活"）
rm -f /data/adb/post-fs-data.d/fjguard_hook.sh 2>/dev/null
rm -f /data/adb/service.d/fjguard_hook.sh 2>/dev/null
rm -f "$STASH/.enabled" 2>/dev/null
rm -rf "$STASH" 2>/dev/null

# 4) 清理状态目录
rm -rf "$STATE" 2>/dev/null

echo "- FJGuard 已卸载；备份保留在 /sdcard/FJGuard"
exit 0
