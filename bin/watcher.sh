#!/system/bin/sh
# FJGuard L2：inotify 实时回滚层
# 监听关键目录的删除/移出事件，命中基线内文件立即回写

_BD=$(dirname "$0")/common.sh
[ -f "$_BD" ] || _BD=/data/adb/fjguard/rt/common.sh
[ -f "$_BD" ] || _BD=/data/adb/modules/fjguard/bin/common.sh
. "$_BD"

fjg_init_dirs
fjg_lock watcher || exit 0
trap 'fjg_unlock watcher' EXIT INT TERM HUP
echo $$ > "$RUNDIR/watcher.pid"

fjg_log watcher started "监听目录数=$(fjg_watch_dirs | wc -w)"

WATCHSET=$(fjg_watch_dirs)
while :; do
    if [ -e "$FLAG_DISABLE" ]; then
        sleep 10
        continue
    fi
    if [ ! -f "$RT/onchange.sh" ]; then
        sleep 5
        continue
    fi
    /system/bin/inotifyd "$RT/onchange.sh" $WATCHSET >>"$LOGDIR/watcher.log" 2>&1 &
    _wp=$!
    echo "$_wp" > "$RUNDIR/watcher.pid"
    while kill -0 "$_wp" 2>/dev/null; do
        sleep 60
        _new=$(fjg_watch_dirs)
        if [ "$_new" != "$WATCHSET" ]; then
            WATCHSET="$_new"
            kill "$_wp" 2>/dev/null
            break
        fi
    done
    sleep 3
done
