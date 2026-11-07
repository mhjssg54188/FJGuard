#!/system/bin/sh
# FJGuard 管理命令
# 用法:
#   ctl.sh status            查看状态
#   ctl.sh log [N]           查看事件日志（默认 20 行）
#   ctl.sh blocked [N]       查看拦截记录
#   ctl.sh on|off            启用/停用防护（停用会立即杀掉守护）
#   ctl.sh logonly on|off    只记录不拦截模式
#   ctl.sh allow             放行 60 秒（做刷机/系统维护这类操作前用）
#   ctl.sh start|stop        启动/停止守护
#   ctl.sh baseline          重建基线快照
#   ctl.sh restore <路径>    从基线恢复单个文件
#   ctl.sh restore --all     全量恢复所有缺失/损坏条目
#   ctl.sh selftest          自检

_BD=$(dirname "$0")/common.sh
[ -f "$_BD" ] || _BD=/data/adb/fjguard/rt/common.sh
[ -f "$_BD" ] || _BD=/data/adb/modules/fjguard/bin/common.sh
. "$_BD"

fjg_init_dirs

fjg_start() {
    if [ -e "$FLAG_DISABLE" ]; then
        echo "模块处于停用状态，先执行 ctl.sh on"
        return 1
    fi
    nohup "$RT/supervisor.sh" A >>"$LOGDIR/supervisor.log" 2>&1 &
    sleep 1
    nohup "$RT/supervisor.sh" B >>"$LOGDIR/supervisor.log" 2>&1 &
    sleep 2
    fjg_log ctl start "手动启动守护"
    echo "守护已启动"
}

fjg_stop() {
    echo 1 > "$FLAG_DISABLE"
    for _n in supervisor_A supervisor_B procguard watcher integrity; do
        _p=$(cat "$RUNDIR/$_n.pid" 2>/dev/null)
        [ -n "$_p" ] && kill -KILL "$_p" 2>/dev/null
        rm -f "$RUNDIR/$_n.pid" 2>/dev/null
    done
    # inotifyd 子进程
    # 结束 inotifyd 子进程（Android 无 pgrep，扫 /proc）
    for _d in /proc/[0-9]*; do
        _p=${_d#/proc/}
        [ -r "$_d/cmdline" ] || continue
        $BB grep -qa 'onchange.sh' "$_d/cmdline" 2>/dev/null && kill -KILL "$_p" 2>/dev/null
    done
    fjg_log ctl stop "手动停止守护"
    echo "守护已停止（防护关闭）"
}

case "${1:-status}" in
status)
    echo "== FJGuard $FJG_VERSION =="
    if [ -e "$FLAG_DISABLE" ]; then echo "状态: 已停用（$FLAG_DISABLE 存在）"; else echo "状态: 运行中"; fi
    if [ -e "$FLAG_LOGONLY" ]; then echo "模式: 仅记录（不拦截）"; else echo "模式: 主动拦截"; fi
    echo "配置: 扫描 ${PROC_INTERVAL}s / 巡检 ${INTEGRITY_INTERVAL}s / immutable=${IMMUTABLE} / 监控SD=${BLOCK_SDCARD}"
    for _n in supervisor_A supervisor_B procguard watcher integrity; do
        if fjg_alive "$_n"; then _s="运行中 pid=$(cat "$RUNDIR/$_n.pid" 2>/dev/null)"; else _s="未运行"; fi
        printf '  %-14s %s\n' "$_n" "$_s"
    done
    if [ -f "$INDEX" ]; then
        echo "基线: $(wc -l < "$INDEX") 项，建立于 $(cat "$STATE/baseline.time" 2>/dev/null || echo 未知)"
    else
        echo "基线: 尚未建立"
    fi
    echo "运行时副本: $($BB lsattr "$RT/procguard.sh" 2>/dev/null | $BB cut -c1-20)"
    _av=$($BB df -m /data 2>/dev/null | $BB awk 'NR==2{print $4"MB 可用"}')
    echo "/data: $_av"
    echo "今日拦截: $(_d=$(date +%Y-%m-%d); $BB grep -c "^$_d" "$LOGDIR/blocked.log" 2>/dev/null || echo 0) 次"
    ;;
log)
    _n=${2:-20}
    tail -n "$_n" "$LOGDIR/events.log" 2>/dev/null || echo "（暂无日志）"
    ;;
blocked)
    _n=${2:-20}
    tail -n "$_n" "$LOGDIR/blocked.log" 2>/dev/null || echo "（暂无拦截记录）"
    ;;
on)
    rm -f "$FLAG_DISABLE" 2>/dev/null
    fjg_start
    ;;
off)
    fjg_stop
    ;;
logonly)
    case "${2:-on}" in
    on)  touch "$FLAG_LOGONLY"; echo "已切换为仅记录模式";;
    off) rm -f "$FLAG_LOGONLY"; echo "已切回主动拦截";;
    *)   echo "用法: ctl.sh logonly on|off"; exit 2;;
    esac
    ;;
allow)
    touch "$FLAG_ALLOW"
    echo "已放行 60 秒：这段时间内的删除/写入不会被拦截"
    ;;
start)
    rm -f "$FLAG_DISABLE" 2>/dev/null
    fjg_start
    ;;
stop)
    fjg_stop
    ;;
baseline)
    sh "$RT/snapshot.sh" --refresh && echo "基线已重建"
    ;;
restore)
    case "${2:-}" in
    "")
        echo "用法: ctl.sh restore <绝对路径> | ctl.sh restore --all"; exit 2;;
    --all)
        fjg_repair_missing
        fjg_repair_broken
        echo "全量检查完成"
        ;;
    *)
        if fjg_restore_one "$2"; then echo "已恢复: $2"; else echo "恢复失败: $2（无快照或写入失败）"; exit 1; fi
        ;;
    esac
    ;;
selftest)
    _ok=0; _bad=0
    chk() { if [ "$2" = "0" ]; then echo "  [OK]   $1"; _ok=$((_ok+1)); else echo "  [FAIL] $1"; _bad=$((_bad+1)); fi; }
    [ -x "$RT/procguard.sh" ]; chk "运行时副本存在" $?
    [ -f "$INDEX" ]; chk "基线索引存在" $?
    $BB lsattr "$RT/procguard.sh" 2>/dev/null | $BB grep -q 'i'; chk "运行时副本已加 immutable 锁（防删除）" $?
    chcon --help >/dev/null 2>&1; chk "SELinux chcon 可用" $?
    test -w /data/system 2>/dev/null || true
    [ -r /data/system/locksettings.db ]; chk "关键文件可读" $?
    fjg_alive procguard; chk "进程拦截守护运行中" $?
    fjg_alive watcher; chk "实时回滚监听运行中" $?
    fjg_alive integrity; chk "完整性巡检运行中" $?
    _w=$(fjg_watch_dirs 2>/dev/null | wc -w)
    echo "  [info] 监听目录 $_w 个"
    echo "结果: $_ok 通过 / $_bad 失败"
    [ "$_bad" = "0" ] && exit 0 || exit 1
    ;;
*)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
exit 0
