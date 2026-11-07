#!/system/bin/sh
# FJGuard L3：完整性巡检（定时兜底）
# 负责：缺失回填、损坏重建、空间预警

_BD=$(dirname "$0")/common.sh
[ -f "$_BD" ] || _BD=/data/adb/fjguard/rt/common.sh
[ -f "$_BD" ] || _BD=/data/adb/modules/fjguard/bin/common.sh
. "$_BD"

fjg_init_dirs
fjg_lock integrity || exit 0
trap 'fjg_unlock integrity' EXIT INT TERM HUP
echo $$ > "$RUNDIR/integrity.pid"

fjg_log integrity started "间隔=${INTEGRITY_INTERVAL}s"

while :; do
    if [ -e "$FLAG_DISABLE" ]; then
        sleep 15
        continue
    fi
    # L1 拦截后留下的即时修复请求
    if [ -f "$RUNDIR/need_repair" ]; then
        rm -f "$RUNDIR/need_repair" 2>/dev/null
        fjg_repair_missing
        fjg_repair_broken
    fi
    fjg_repair_missing
    fjg_repair_broken
    fjg_space_check
    sleep "$INTEGRITY_INTERVAL"
done
