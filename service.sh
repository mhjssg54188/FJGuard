#!/system/bin/sh
# FJGuard 服务阶段：拉起双守护（互保监督者 + 三工作守护）

MODDIR=${0%/*}
[ -d "$MODDIR/bin" ] || MODDIR=/data/adb/modules/fjguard
_BD="$MODDIR/bin/common.sh"
[ -f "$_BD" ] || _BD=/data/adb/fjguard/rt/common.sh
[ -f "$_BD" ] || _BD=/data/adb/modules/fjguard/bin/common.sh
[ -f "$_BD" ] || exit 0
. "$_BD"

[ -e "$FLAG_DISABLE" ] && exit 0

fjg_init_dirs
[ -d "$MODDIR/bin" ] && fjg_sync_rt "$MODDIR/bin"
[ -f "$RT/supervisor.sh" ] || exit 0

# 已有实例就只补缺失角色
if ! fjg_alive supervisor_A; then
    nohup "$RT/supervisor.sh" A >>"$LOGDIR/supervisor.log" 2>&1 &
fi
sleep 1
if ! fjg_alive supervisor_B; then
    nohup "$RT/supervisor.sh" B >>"$LOGDIR/supervisor.log" 2>&1 &
fi

fjg_log boot service "守护已拉起"
exit 0
