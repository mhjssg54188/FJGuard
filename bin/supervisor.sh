#!/system/bin/sh
# FJGuard L4：守护进程监督者
# 双实例互保：A 与 B 互相确保对方活着，并各自确保三个工作守护活着
# 用法：supervisor.sh A|B  （同一角色只允许一个实例，flock 互斥）

_BD=$(dirname "$0")/common.sh
[ -f "$_BD" ] || _BD=/data/adb/fjguard/rt/common.sh
[ -f "$_BD" ] || _BD=/data/adb/modules/fjguard/bin/common.sh
. "$_BD"

ROLE="${1:-A}"
case "$ROLE" in A|B) ;; *) ROLE=A;; esac

fjg_init_dirs
fjg_lock "supervisor_$ROLE" || exit 0
trap 'fjg_unlock "supervisor_$ROLE"' EXIT INT TERM HUP
echo $$ > "$RUNDIR/supervisor_$ROLE.pid"

fjg_ensure() {   # 名称 脚本
    if ! fjg_alive "$1"; then
        $BB nice -n 19 nohup "$2" >>"$LOGDIR/$1.log" 2>&1 &
        echo $! > "$RUNDIR/$1.pid" 2>/dev/null
        fjg_log daemon restart "$1"
    fi
}

while :; do
    if [ -e "$FLAG_DISABLE" ]; then
        sleep 10
        continue
    fi
    fjg_ensure procguard "$RT/procguard.sh"
    fjg_ensure watcher   "$RT/watcher.sh"
    fjg_ensure integrity "$RT/integrity.sh"

    # 对等监督
    if [ "$ROLE" = "A" ]; then _peer=B; else _peer=A; fi
    if ! fjg_alive "supervisor_$_peer"; then
        nohup "$RT/supervisor.sh" "$_peer" >>"$LOGDIR/supervisor.log" 2>&1 &
        fjg_log daemon "restart-peer" "supervisor_$_peer"
    fi
    sleep 30
done
