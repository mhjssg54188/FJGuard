#!/system/bin/sh
# FJGuard L2 事件处理器：由 inotifyd 逐事件调用
# 参数：EVENTS DIRFILE [SUBFILE]
#   子项事件 d=删除 y=移出 n=新建 m=移入 e=元数据变化
#   目录自身事件 D=被删除 M=被移动

_BD=$(dirname "$0")/common.sh
[ -f "$_BD" ] || _BD=/data/adb/fjguard/rt/common.sh
[ -f "$_BD" ] || _BD=/data/adb/modules/fjguard/bin/common.sh
. "$_BD"

[ -e "$FLAG_DISABLE" ] && exit 0

_ev=${1:-}
_dir=${2:-}
_name=${3:-}
[ -n "$_dir" ] || exit 0

_target="$_dir"
_hit=0
case "$_ev" in
    *d*|*y*) [ -n "$_name" ] && _target="$_dir/$_name"; _hit=1;;
    *D*) _target="$_dir"; _hit=1;;
esac
[ "$_hit" = "1" ] || exit 0
[ -f "$INDEX" ] || exit 0

# 单个回写加锁：并发删除时只让一个实例做事，避免 fork 风暴
[ -d "$RUNDIR" ] || fjg_init_dirs
fjg_lock restore || exit 0
trap 'fjg_unlock restore' EXIT INT TERM HUP

if [ -e "$_target" ]; then
    # 仍存在（移出后又移回等）：只记日志
    exit 0
fi

if fjg_index_get "$_target" >/dev/null 2>&1; then
    fjg_log watch removed "$_target"
    fjg_restore_one "$_target"
    exit 0
fi

# 目录被整体删除：恢复其下所有基线内条目
fjg_restore_tree "$_target"
fjg_log watch "tree-removed" "$_target"
exit 0
