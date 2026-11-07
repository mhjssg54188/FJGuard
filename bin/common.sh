#!/system/bin/sh
# FJGuard 公共库 —— 路径、配置、日志、快照索引、还原、自愈
# 被其余所有脚本 source；不单独执行

FJG_VERSION=v1.0.3

STATE=${FJG_STATE:-/data/adb/fjguard}
RT=$STATE/rt
BASE=$STATE/baseline
MIRROR=$BASE/root
RUNDIR=$STATE/run
LOGDIR=$STATE/log
CFG=$STATE/guard.conf
INDEX=$STATE/baseline.idx
FLAG_DISABLE=$STATE/DISABLED
FLAG_LOGONLY=$STATE/LOG_ONLY
FLAG_ALLOW=$STATE/ALLOW_ONCE
STASH=${FJG_STASH:-/data/local/fjguard_stash}
SDMIR=${FJG_SDMIR:-/sdcard/FJGuard}
MODDIR=/data/adb/modules/fjguard

# busybox 探测：Magisk / KernelSU / APatch / 系统自带，最后退回 PATH 上的 toybox 工具
BB=""
for _cand in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
             /data/adb/apatch/bin/busybox /data/adb/apd/busybox \
             /system/bin/busybox /system/xbin/busybox; do
    if [ -x "$_cand" ]; then
        BB="$_cand"
        break
    fi
done
PATH=/data/adb/magisk:/data/adb/magisk/bin:/data/adb/ksu/bin:/data/adb/ap/bin:/system/bin:/system/xbin:/vendor/bin:/product/bin:/odm/bin
export PATH

# 默认配置（guard.conf 覆盖）
PROC_INTERVAL=0.6
INTEGRITY_INTERVAL=90
IMMUTABLE=1
WATCH_MODULES=1
BLOCK_SDCARD=1
BLOCK_PM_CLEAR=1
FREE_WARN_MB=1024
LOG_MAX_KB=512
NOTIFY=1

if [ -f "$CFG" ]; then . "$CFG"; fi

fjg_init_dirs() {
    mkdir -p "$STATE" "$RT" "$BASE" "$MIRROR" "$RUNDIR" "$LOGDIR" 2>/dev/null
    chmod 700 "$STATE" "$RT" "$BASE" "$RUNDIR" "$LOGDIR" 2>/dev/null
    return 0
}

fjg_now() { date '+%Y-%m-%d %H:%M:%S'; }

fjg_rotate() {
    [ -f "$1" ] || return 0
    _sz=$($BB stat -c %s "$1" 2>/dev/null)
    [ -n "$_sz" ] || return 0
    [ "$_sz" -gt $(( ${2:-512} * 1024 )) ] && mv -f "$1" "$1.1" 2>/dev/null
    return 0
}

fjg_log() {   # 层|动作|详情
    [ -d "$LOGDIR" ] || return 0
    printf '%s|%s|%s|%s\n' "$(fjg_now)" "$1" "$2" "$3" >> "$LOGDIR/events.log" 2>/dev/null
    fjg_rotate "$LOGDIR/events.log" "$LOG_MAX_KB"
    return 0
}

fjg_notify() {   # 标题|正文
    [ "${NOTIFY:-1}" = "1" ] || return 0
    _now=$(date +%s)
    _last=$(cat "$RUNDIR/notify.ts" 2>/dev/null)
    if [ -n "$_last" ]; then
        [ $(( _now - _last )) -lt 15 ] && return 0
    fi
    echo "$_now" > "$RUNDIR/notify.ts" 2>/dev/null
    cmd notification post -S bigtext -t "$1" fjguard "$2" >/dev/null 2>&1 &
    return 0
}

# ---------------- 进程工具 ----------------
fjg_comm() {   # pid -> comm
    IFS= read -r _c < "/proc/$1/comm" 2>/dev/null || { echo ""; return 1; }
    echo "$_c"
}

fjg_ppid() {   # pid -> 父 pid
    _l=$($BB grep -m1 '^PPid:' "/proc/$1/status" 2>/dev/null)
    echo "${_l#PPid:}" | $BB tr -d ' \t\r'
}

fjg_cmdline() {   # pid -> 空格分隔的完整命令行（前后各补一个空格）
    _v=$($BB tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null)
    echo " $_v "
}

fjg_alive() {   # 守护名 -> 0=活着（校验 cmdline 归属，防 pid 复用误判）
    _p=$(cat "$RUNDIR/$1.pid" 2>/dev/null)
    [ -n "$_p" ] || return 1
    [ -r "/proc/$_p/cmdline" ] || return 1
    $BB grep -qa 'fjguard' "/proc/$_p/cmdline" 2>/dev/null && return 0
    return 1
}

fjg_allow_recent() {   # ALLOW_ONCE 文件 60 秒内 → 放行
    [ -e "$FLAG_ALLOW" ] || return 1
    _n=$(date +%s); _m=$($BB stat -c %Y "$FLAG_ALLOW" 2>/dev/null)
    [ -n "$_m" ] || return 1
    [ $(( _n - _m )) -lt 60 ] && return 0
    rm -f "$FLAG_ALLOW" 2>/dev/null
    return 1
}

# ---------------- 快照索引 ----------------
fjg_meta() {   # 文件 -> 权限|uid|gid|上下文|大小|sha256
    _f=$1
    _ctx=$($BB ls -Z "$_f" 2>/dev/null | $BB awk '{print $1}')
    _m=$($BB stat -c '%a %u %g %s' "$_f" 2>/dev/null)
    set -- $_m
    _mode=${1:-600}; _uid=${2:-0}; _gid=${3:-0}; _size=${4:-0}
    _sha=$($BB sha256sum "$_f" 2>/dev/null | $BB awk '{print $1}')
    printf '%s|%s|%s|%s|%s|%s' "$_mode" "$_uid" "$_gid" "${_ctx:-u:object_r:system_data_file:s0}" "$_size" "${_sha:-none}"
}

fjg_index_get() {   # 路径 -> 索引行
    [ -f "$INDEX" ] || return 1
    $BB grep -F -m1 "$1|" "$INDEX" 2>/dev/null
}

fjg_index_field() {   # 路径 字段号(2-7)
    _line=$(fjg_index_get "$1")
    [ -n "$_line" ] || return 1
    IFS='|' read -r _a _b _c _d _e _f _g <<EOF
$_line
EOF
    case "$2" in
        2) echo "$_b";; 3) echo "$_c";; 4) echo "$_d";;
        5) echo "$_e";; 6) echo "$_f";; 7) echo "$_g";;
    esac
}

# ---------------- 还原 ----------------
fjg_restore_one() {   # 路径 -> 0=成功
    _p=$1
    _src="$MIRROR$_p"
    if [ ! -f "$_src" ]; then
        fjg_log restore miss "$_p（无快照）"
        return 1
    fi
    _dir=$(dirname "$_p")
    [ -d "$_dir" ] || mkdir -p "$_dir" 2>/dev/null
    _mode=600; _uid=1000; _gid=1000; _ctx=u:object_r:system_data_file:s0
    _line=$(fjg_index_get "$_p")
    if [ -n "$_line" ]; then
        # 第一列是路径，必须一起读走，否则字段整体错位（会把权限位当属主）
        IFS='|' read -r _x_p _x_mode _x_uid _x_gid _x_ctx _x_sz _x_sha <<EOF
$_line
EOF
        [ -n "$_x_mode" ] && _mode=$_x_mode
        [ -n "$_x_uid" ] && _uid=$_x_uid
        [ -n "$_x_gid" ] && _gid=$_x_gid
        [ -n "$_x_ctx" ] && _ctx=$_x_ctx
    fi
    # 索引被污染时的兜底：权限位形状的值绝不能当属主/上下文用
    case "$_mode" in
        [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7]) ;;
        *) _mode=600;;
    esac
    case "$_uid" in
        ''|*[!0-9]*) _uid=1000;;
        400|444|600|604|640|644|660|664|666|700|750|755|770|775)
            fjg_log restore warn "$_p 索引属主异常($_uid)，回落 1000:1000"
            _uid=1000; _gid=1000;;
    esac
    case "$_ctx" in
        u:object_r:*) ;;
        *) _ctx=u:object_r:system_data_file:s0;;
    esac
    _tmp="$_p.fjg.$$"
    if ! cp -f "$_src" "$_tmp" 2>/dev/null; then
        fjg_log restore fail "$_p（写入失败）"
        rm -f "$_tmp" 2>/dev/null
        return 1
    fi
    chown "$_uid:$_gid" "$_tmp" 2>/dev/null
    chmod "$_mode" "$_tmp" 2>/dev/null
    chcon "$_ctx" "$_tmp" 2>/dev/null
    if ! mv -f "$_tmp" "$_p" 2>/dev/null; then
        fjg_log restore fail "$_p（落位失败）"
        rm -f "$_tmp" 2>/dev/null
        return 1
    fi
    _cur=$($BB ls -Z "$_p" 2>/dev/null | $BB awk '{print $1}')
    if [ -n "$_cur" ] && [ "$_cur" != "$_ctx" ]; then
        restorecon -F "$_p" >/dev/null 2>&1
        _cur2=$($BB ls -Z "$_p" 2>/dev/null | $BB awk '{print $1}')
        [ "$_cur2" = "$_ctx" ] || fjg_log restore ctxwarn "$_p（上下文 $_cur2）"
    fi
    _v=$($BB stat -c '%a|%u|%g' "$_p" 2>/dev/null)
    [ "$_v" = "$_mode|$_uid|$_gid" ] || fjg_log restore attrwarn "$_p（期望 $_mode|$_uid|$_gid 实际 $_v）"
    fjg_log restore ok "$_p"
    return 0
}

fjg_valid() {   # 文件是否为结构完好的 db/xml（0=正常）
    _f=$1
    # SQLite 边车文件内容一直在变，只校验存在性，不做结构判定
    case "$_f" in
        *.db-wal|*.db-shm|*.db-journal) return 0;;
    esac
    [ -f "$_f" ] || return 1
    _sz=$($BB stat -c %s "$_f" 2>/dev/null)
    [ -n "$_sz" ] || return 1
    [ "$_sz" -gt 0 ] || return 1
    case "$_f" in
        *.db)
            _h=$($BB head -c 15 "$_f" 2>/dev/null)
            [ "$_h" = "SQLite format 3" ] && return 0
            # 无 SQLite 文件头 = 已被垃圾覆盖/截断，需要重建
            return 1
            ;;
        *.xml)
            _h=$($BB head -c 8 "$_f" 2>/dev/null)
            # Android 13 起 /data/system 下的 xml 多为 ABX 二进制格式
            case "$_h" in
                "ABX"*)  return 0;;
                "<"*)    return 0;;
            esac
            return 1
            ;;
    esac
    return 0
}

fjg_repair_missing() {   # 恢复所有缺失的关键文件
    [ -f "$INDEX" ] || return 0
    _n=0
    while IFS='|' read -r _p _rest; do
        [ -n "$_p" ] || continue
        [ -e "$_p" ] && continue
        fjg_restore_one "$_p" && _n=$(( _n + 1 ))
    done < "$INDEX"
    if [ "$_n" -gt 0 ]; then
        fjg_log repair restored "$_n 个缺失文件"
        fjg_notify "[FJGuard] 已自动修复" "恢复了 $_n 个被删除的关键文件"
    fi
    return 0
}

fjg_repair_broken() {   # 被写坏（非 SQLite / 非 XML）的关键文件
    [ -f "$INDEX" ] || return 0
    _n=0
    while IFS='|' read -r _p _rest; do
        [ -n "$_p" ] || continue
        [ -e "$_p" ] || continue
        case "$_p" in
            *.db|*.xml) ;;
            *) continue;;
        esac
        fjg_valid "$_p" && continue
        fjg_restore_one "$_p" && _n=$(( _n + 1 ))
    done < "$INDEX"
    if [ "$_n" -gt 0 ]; then
        fjg_log repair rebuilt "$_n 个损坏文件"
        fjg_notify "[FJGuard] 已重建关键文件" "修复 $_n 个被写坏的数据库/配置"
    fi
    return 0
}

fjg_space_check() {
    _av=$($BB df -m /data 2>/dev/null | $BB awk 'NR==2{print $4}')
    [ -n "$_av" ] || return 0
    case "$_av" in ''|*[!0-9]*) return 0;; esac
    if [ "$_av" -lt "${FREE_WARN_MB:-1024}" ]; then
        fjg_log space warn "/data 剩余 ${_av}MB"
        fjg_notify "[FJGuard] 存储将满" "/data 仅剩 ${_av}MB，低于 ${FREE_WARN_MB}MB 预警线，可能是磁盘填充攻击"
    fi
    return 0
}

# ---------------- 运行时副本同步（自保护：chattr +i）----------------
fjg_sync_rt() {   # $1 = 源目录（模块 bin/）
    _src=$1
    [ -d "$_src" ] || return 0
    mkdir -p "$RT" 2>/dev/null
    for _f in "$_src"/*.sh; do
        [ -f "$_f" ] || continue
        _b=$(basename "$_f")
        _tgt="$RT/$_b"
        if [ -f "$_tgt" ]; then
            _a=$($BB sha256sum "$_f" 2>/dev/null | $BB awk '{print $1}')
            _b2=$($BB sha256sum "$_tgt" 2>/dev/null | $BB awk '{print $1}')
            [ "$_a" = "$_b2" ] && continue
            [ "$IMMUTABLE" = "1" ] && chattr -i "$_tgt" 2>/dev/null
        fi
        cp -f "$_f" "$_tgt" 2>/dev/null
        chmod 755 "$_tgt" 2>/dev/null
        [ "$IMMUTABLE" = "1" ] && chattr +i "$_tgt" 2>/dev/null
    done
    [ -f "$_src/../config/guard.conf" ] && [ ! -f "$CFG" ] && cp -f "$_src/../config/guard.conf" "$CFG" 2>/dev/null
    return 0
}

fjg_unprotect() {   # 解除 immutable（卸载/更新前）
    [ -d "$RT" ] || return 0
    for _f in "$RT"/*.sh; do
        [ -f "$_f" ] && chattr -i "$_f" 2>/dev/null
    done
    if [ -d "$BASE" ]; then
        find "$BASE" -type f 2>/dev/null | while IFS= read -r _f; do chattr -i "$_f" 2>/dev/null; done
    fi
    return 0
}

fjg_restore_tree() {   # 目录 -> 恢复其下所有基线条目
    [ -f "$INDEX" ] || return 0
    _n=0
    _pfx="$1/"
    while IFS='|' read -r _p _rest; do
        [ -n "$_p" ] || continue
        case "$_p" in
            "$_pfx"*) [ -e "$_p" ] || { fjg_restore_one "$_p" && _n=$(( _n + 1 )); };;
        esac
    done < "$INDEX"
    if [ "$_n" -gt 0 ]; then
        fjg_log restore tree "$1 下恢复 $_n 项"
        fjg_notify "[FJGuard] 目录被删除已回滚" "$1
恢复了 $_n 个文件"
    fi
    return 0
}

fjg_watch_dirs() {   # 需要监听的目录清单（含掩码）
    _o=""
    for _d in /data/system /data/system/users /data/system/users/0 \
              /data/adb /data/adb/modules /data/adb/post-fs-data.d \
              /data/adb/service.d /data/adb/boot-completed.d; do
        [ -d "$_d" ] && _o="$_o $_d:eDndmy"
    done
    if [ "${WATCH_MODULES:-1}" = "1" ]; then
        for _m in /data/adb/modules/*/; do
            [ -d "$_m" ] && _o="$_o ${_m%/}:eDndmy"
        done
    fi
    echo "$_o"
}

# ---------------- 互斥锁（mkdir 原子锁，兼容无 flock 的环境） ----------------
fjg_lock() {   # 锁名 -> 0=获得
    _lk="$RUNDIR/$1.lock.d"
    mkdir -p "$RUNDIR" 2>/dev/null
    if mkdir "$_lk" 2>/dev/null; then
        echo $$ > "$_lk/pid" 2>/dev/null
        return 0
    fi
    # 已有锁：持有者已死则接管
    _lp=$(cat "$_lk/pid" 2>/dev/null)
    if [ -n "$_lp" ] && kill -0 "$_lp" 2>/dev/null; then
        return 1
    fi
    rm -rf "$_lk" 2>/dev/null
    mkdir "$_lk" 2>/dev/null || return 1
    echo $$ > "$_lk/pid" 2>/dev/null
    return 0
}

fjg_unlock() {   # 锁名
    _lk="$RUNDIR/$1.lock.d"
    _lp=$(cat "$_lk/pid" 2>/dev/null)
    [ "$_lp" = "$$" ] && rm -rf "$_lk" 2>/dev/null
    return 0
}
