#!/system/bin/sh
# FJGuard L1：破坏性指令实时拦截
# 设计：每轮只对"新出现的进程"做命令行解析（零子进程读 comm），
#       另有周期性全量扫描兜底；命中即 SIGSTOP→SIGKILL 并触发即时修复。

_BD=$(dirname "$0")/common.sh
[ -f "$_BD" ] || _BD=/data/adb/fjguard/rt/common.sh
[ -f "$_BD" ] || _BD=/data/adb/modules/fjguard/bin/common.sh
. "$_BD"

fjg_init_dirs
echo $$ > "$RUNDIR/procguard.pid"

FJG_RULE=""
FJG_DETAIL=""
FJG_HIT=""
FJG_LAST=""
BLOCKS=0

# ---------- 路径判定 ----------
fjg_allowed_path() {   # 0=允许操作（日常清理/缓存类，避免误伤）
    case "$1" in
        /data/local/tmp|/data/local/tmp/*) return 0;;
        /data/local/Dsh|/data/local/Dsh/*|/data/local/dsh|/data/local/dsh/*) return 0;;
        /data/data/*/cache|/data/data/*/cache/*) return 0;;
        /data/user*/*/cache|/data/user*/*/cache/*) return 0;;
        /data/dalvik-cache/*|/data/log*|/data/anr*|/data/tombstones*) return 0;;
        /data/misc/logd*|/data/misc/dumpstate*|/data/misc/adb*) return 0;;
        /data/system/dropbox*|/data/system/recent*|/data/system/usagestats*) return 0;;
        /data/media/0/Android/data*|/data/media/0/Android/media*) return 0;;
        /sdcard/Android/data*|/sdcard/Android/media*|/sdcard/Android/obb*) return 0;;
        /storage/emulated/*/Android/data*|/storage/emulated/*/Android/media*) return 0;;
        /data/local/fjguard_stash|/data/local/fjguard_stash/*) return 0;;
    esac
    return 1
}

fjg_args_only() {   # 去掉 argv[0]，只留参数（argv[0] 常是 /system/bin/sh，绝不能当攻击目标）
    FJG_ARGS="${1# }"
    FJG_ARGS="${FJG_ARGS#* }"
}

fjg_scan_targets() {   # 任意破坏性目标 → FJG_HIT
    FJG_HIT=""
    for _w in $1; do
        case "$_w" in
            -*) continue;;
            /data|/data/|/data/system|/data/system/|/data/system_ce|/data/system_de|/data/data|/data/data/|\
            /data/app|/data/app/|/data/adb|/data/adb/|/data/media|/data/media/|/data/user|/data/user/|\
            /data/user_de|/data/misc|/data/misc/|/data/vendor|/data/vendor/|/data/dalvik-cache|/data/local|/data/local/)
                FJG_HIT="$_w"; return 0;;
            /system|/system/|/system_root|/system_root/|/vendor|/vendor/|/product|/product/|/odm|/odm/|\
            /boot|/cache|/cache/|/persist|/persist/|/metadata|/metadata/|/mnt/vendor)
                FJG_HIT="$_w"; return 0;;
            # 整卷 / 媒体目录本身
            /sdcard|/sdcard/|/storage/emulated|/storage/emulated/|/storage/emulated/0|/storage/emulated/0/|\
            /sdcard/DCIM|/sdcard/DCIM/|/sdcard/Pictures|/sdcard/Pictures/|/sdcard/Download|/sdcard/Download/|\
            /sdcard/Movies|/sdcard/Movies/|/sdcard/Music|/sdcard/Music/|/sdcard/Documents|/sdcard/Documents/|\
            /sdcard/Android|/sdcard/Android/|/storage/emulated/0/DCIM|/storage/emulated/0/DCIM/|\
            /storage/emulated/0/Pictures|/storage/emulated/0/Pictures/|/storage/emulated/0/Download|/storage/emulated/0/Download/)
                if [ "${BLOCK_SDCARD:-1}" = "1" ]; then FJG_HIT="$_w"; return 0; fi;;
            # 媒体目录下的路径：仅"整目录通配"（含字面 *）算清空，深层具体路径放行
            /sdcard/*/*|/storage/emulated/0/*/*)
                case "$_w" in
                    /sdcard/DCIM/*|/sdcard/Pictures/*|/storage/emulated/0/DCIM/*|/storage/emulated/0/Pictures/*)
                        if [ "${BLOCK_SDCARD:-1}" = "1" ]; then FJG_HIT="$_w"; return 0; fi;;
                    *\**)
                        if [ "${BLOCK_SDCARD:-1}" = "1" ]; then FJG_HIT="$_w"; return 0; fi;;
                esac;;
            # 注意：不保护 /system/* /vendor/* 等只读分区下的普通路径——
            # 这类路径常出现在 argv 与正常命令里，且 Android 13 上本就只读，拦它只会造成误判
            /data/*|/sdcard/*|/storage/*)
                fjg_allowed_path "$_w" || { FJG_HIT="$_w"; return 0; };;
        esac
    done
    return 1
}

fjg_last_abs() {   # 最后一个绝对路径（写入目标）
    FJG_LAST=""
    for _w in $1; do
        case "$_w" in /*) FJG_LAST="$_w";; esac
    done
    [ -n "$FJG_LAST" ]
}

fjg_crit_path() {   # 关键文件判定 → FJG_DETAIL
    FJG_DETAIL=""
    for _w in $1; do
        case "$_w" in
            *locksettings.db*|*packages.xml*|*packages.list*|*device_policies.xml*|\
            *"/data/system/users"*|*"/data/system_de"*|*magisk.db*|*"/data/adb/magisk"*|\
            *"/data/adb/ksu"*|*"/data/adb/ap"*|*"/data/adb/apd"*|\
            *"/data/adb/modules"*|*"/data/adb/post-fs-data.d"*|*"/data/adb/service.d"*|\
            *"/data/adb/boot-completed.d"*|*"/data/adb/fjguard"*|*"/data/system/locksettings"*)
                FJG_DETAIL="$_w"; return 0;;
        esac
    done
    return 1
}

# ---------- 规则匹配 ----------
fjg_cmd_is_ours() {   # 命令行是否就是守护自身脚本（按 argv[0] 归属判定，不能用"包含 fjguard"，否则攻击者可借自我豁免）
    case "$1" in
        " /system/bin/sh /data/adb/fjguard/rt/"*|" /data/adb/fjguard/rt/"*|\
        " /system/bin/sh /data/adb/modules/fjguard/"*|" /system/bin/sh /data/local/fjguard_stash/"*)
            return 0;;
    esac
    return 1
}

fjg_self_chain() {   # pid 是否守护自身或其子孙
    _p=$1
    _i=0
    while [ "$_i" -lt 4 ]; do
        case "$_p" in ''|0|1) return 1;; esac
        _cl=$(fjg_cmdline "$_p")
        fjg_cmd_is_ours "$_cl" && return 0
        _p=$(fjg_ppid "$_p")
        _i=$(( _i + 1 ))
    done
    return 1
}

fjg_match() {   # $1=命令行（前后带空格）→ FJG_RULE
    FJG_RULE=""
    _c=$1
    fjg_cmd_is_ours "$_c" && return 0

    # R1 直接写裸块设备
    case "$_c" in
        *"of=/dev/block"*|*"of= /dev/block"*|*">/dev/block"*|*"> /dev/block"*|*"dd of=/dev/sd"*)
            FJG_RULE="DD_BLOCK"; return 0;;
    esac
    # R2 格式化 / 改分区表
    case "$_c" in
        *"/dev/block"*)
            case "$_c" in
                *mkfs*|*mke2fs*|*wipefs*|*tune2fs*|*sgdisk*|*sfdisk*|*parted*|*fdisk*|*"dd if="*)
                    FJG_RULE="MKFS_BLOCK"; return 0;;
            esac;;
    esac
    # R3 工厂重置
    case "$_c" in
        *MASTER_CLEAR*|*"--wipe_data"*|*"--delete_data"*|*"FACTORY_RESET"*|*"recovery --wipe"*)
            FJG_RULE="FACTORY_RESET"; return 0;;
    esac
    # R4 磁盘填充：只认写到关键根（普通 dd 写文件放行，避免误伤）
    case "$_c" in
        *"of=/data "*|*"of=/data/"|*"of=/sdcard "*|*"of=/storage/emulated/0 "*|*"of=/system "*)
            FJG_RULE="DISK_FILL"; return 0;;
    esac
    # R5 批量改权限/属性（只认 -R/--recursive；-r 太常见，如 read -r）
    case "$_c" in
        *" -R "*|*"--recursive"*|*" -Rf "*)
            case "$_c" in
                *chmod*|*chown*|*chattr*)
                    fjg_args_only "$_c"
                    fjg_scan_targets "$FJG_ARGS" && { FJG_RULE="MASS_ATTR:$FJG_HIT"; return 0; };;
            esac;;
    esac
    # R6 pm clear 系统关键包
    if [ "${BLOCK_PM_CLEAR:-1}" = "1" ]; then
        case "$_c" in
            *"pm clear"*|*"pm uninstall --user 0"*)
                case "$_c" in
                    *com.android.systemui*|*com.android.settings*|*com.android.providers.settings*|*com.android.phone*)
                        FJG_RULE="PM_CLEAR"; return 0;;
                esac;;
        esac
    fi
    # R7 关键文件被删除/改名/改写（扫描参数部分，不含 argv[0]）
    case "$_c" in
        *" rm "*|*"/rm "*|*"rmdir "*|*" mv "*|*"/mv "*|*" truncate "*|*" shred "*|\
        *" chattr "*|*"/chattr "*|*" chmod "*|*" chown "*|*" install "*|*" setprop "*)
            fjg_args_only "$_c"
            fjg_crit_path "$FJG_ARGS" && { FJG_RULE="CRIT_FILE:$FJG_DETAIL"; return 0; }
            ;;
        *"cp "*)
            fjg_args_only "$_c"
            if fjg_crit_path "$FJG_ARGS"; then
                fjg_last_abs "$FJG_ARGS"
                # 目标在 /sdcard 上属于"备份出来"，不算覆盖系统文件
                case "$FJG_LAST" in
                    /sdcard*|/storage/emulated*) ;;
                    *locksettings.db*|*packages.xml*|*packages.list*|*device_policies.xml*|*"/data/system/users"*|*magisk.db*)
                        FJG_RULE="CRIT_OVERWRITE:$FJG_LAST"; return 0;;
                esac
            fi
            ;;
        # 重定向覆盖关键文件：必须紧邻目标路径，避免把普通 echo "a>b" 当攻击
        *">"*"/data/system/locksettings.db"*|*">"*"/data/system/packages.xml"*|\
        *">"*"/data/system/packages.list"*|*">"*"/data/system/device_policies.xml"*|\
        *">"*"/data/adb/magisk.db"*)
            fjg_crit_path "$_c" && { FJG_RULE="CRIT_REDIRECT:$FJG_DETAIL"; return 0; }
            ;;
    esac
    # R8 删除关键根目录（扫描参数部分）
    case "$_c" in
        *" rm "*|*"/rm "*|*" rmdir "*|*" rm -"*|*"/rm -"*|*" mv "*|*"/mv "*|*" mv -"*|*" shred "*|*" truncate "*|*" dd "*)
            fjg_args_only "$_c"
            fjg_scan_targets "$FJG_ARGS" && { FJG_RULE="ROOT_RM:$FJG_HIT"; return 0; }
            ;;
    esac
    # R9 cp/mv 覆盖到受保护系统根（只看目标位；/sdcard 不在此列，避免误伤正常拷贝）
    case "$_c" in
        *"cp "*|*"mv "*|*"install "*)
            fjg_args_only "$_c"
            fjg_last_abs "$FJG_ARGS" || return 0
            case "$FJG_LAST" in
                /sdcard*|/storage/emulated*) ;;
                *)
                    fjg_scan_targets "$FJG_LAST" && { FJG_RULE="DEST_WRITE:$FJG_HIT"; return 0; }
                    ;;
            esac
            ;;
    esac
    return 0
}

# ---------- 处置 ----------
fjg_act() {   # pid rule cmd
    _pid=$1; _rule=$2; _cmd=$3
    [ "$_pid" = "$$" ] && return 0
    [ "$_pid" -le 1 ] 2>/dev/null && return 0
    # 守护自身的子孙（如内部 cp/chcon/mv）不得误杀
    fjg_self_chain "$_pid" && return 0
    # 同 pid 同规则 5 秒内只处置一次（僵尸进程会被后续扫描再次命中）
    _key="$_pid|$_rule"
    if [ "$_key" = "$(cat "$RUNDIR/last_block" 2>/dev/null)" ]; then
        _lts=$(cat "$RUNDIR/last_block.ts" 2>/dev/null)
        if [ -n "$_lts" ] && [ $(( $(date +%s) - _lts )) -lt 5 ]; then
            return 0
        fi
    fi
    echo "$_key" > "$RUNDIR/last_block" 2>/dev/null
    date +%s > "$RUNDIR/last_block.ts" 2>/dev/null
    _short=$(echo "$_cmd" | $BB tr "\n" " " | $BB cut -c1-160)

    if [ -e "$FLAG_LOGONLY" ] || fjg_allow_recent; then
        fjg_log guard "observe:$_rule" "pid=$_pid $_short"
        return 0
    fi

    fjg_log guard "block:$_rule" "pid=$_pid $_short"
    printf '%s|%s|%s|%s\n' "$(fjg_now)" "$_rule" "$_pid" "$_short" >> "$LOGDIR/blocked.log" 2>/dev/null
    fjg_rotate "$LOGDIR/blocked.log" "$LOG_MAX_KB"
    BLOCKS=$(( BLOCKS + 1 ))

    _ppid=$(fjg_ppid "$_pid")
    kill -STOP "$_pid" 2>/dev/null
    kill -KILL "$_pid" 2>/dev/null
    # 父进程若是"脚本执行器"（sh 某个 .sh 文件），一并终止，防止换个命令接着来
    # 注意：不杀 `sh -c <内联脚本>` 的父进程，避免误伤运维/自动化外壳
    case "$_ppid" in ''|0|1) ;; *)
        _pc=$(fjg_comm "$_ppid")
        case "$_pc" in
            sh|bash|mksh|ash|toybox|busybox)
                _pcl=$(fjg_cmdline "$_ppid")
                case "$_pcl" in
                    *".sh "*) 
                        kill -KILL "$_ppid" 2>/dev/null
                        fjg_log guard "block:parent" "pid=$_ppid($_pc) 因 $_rule";;
                esac;;
        esac;;
    esac

    date +%s > "$RUNDIR/need_repair" 2>/dev/null
    if [ $(( BLOCKS % 5 )) -eq 1 ]; then
        fjg_notify "[FJGuard] 已拦截格机操作" "$_rule
$_short"
    fi
    return 0
}

# ---------- 扫描 ----------
fjg_check_new() {   # pid（comm 已确认为可疑）
    _p=$1
    _cmd=$(fjg_cmdline "$_p")
    [ -n "$_cmd" ] || return 0
    fjg_match "$_cmd"
    [ -n "$FJG_RULE" ] || return 0
    fjg_act "$_p" "$FJG_RULE" "$_cmd"
}

fjg_suspect_comm() {
    case "$1" in
        sh|bash|mksh|ash|dash|zsh|toybox|busybox|dd|rm|mv|cp|cat|tee|truncate|install|chmod|chown|chattr|\
        setprop|resetprop|mkfs|mkfs.ext4|mkfs.f2fs|mke2fs|tune2fs|wipefs|sgdisk|sfdisk|fdisk|parted|shred|\
        am|pm|reboot|recovery|magisk|su|ksud|apd|sqlite3|flash|fastboot) return 0;;
    esac
    return 1
}

fjg_log guard started "PID=$$ 间隔=${PROC_INTERVAL}s"

KNOWN=" "
ROUND=0
while :; do
    if [ -e "$FLAG_DISABLE" ]; then
        KNOWN=" "; sleep 5; continue
    fi
    ROUND=$(( ROUND + 1 ))
    NEWP=" "
    ALLP=" "
    for _d in /proc/[0-9]*; do
        _pid=${_d#/proc/}
        ALLP="$ALLP$_pid "
        case "$KNOWN" in
            *" $_pid "*) ;;
            *) NEWP="$NEWP$_pid " ;;
        esac
    done
    KNOWN="$ALLP"

    for _pid in $NEWP; do
        [ -r "/proc/$_pid/comm" ] || continue
        IFS= read -r _comm < "/proc/$_pid/comm" 2>/dev/null || continue
        fjg_suspect_comm "$_comm" || continue
        fjg_check_new "$_pid"
    done

    # 每 60 轮（约 36s）全量兜底，覆盖守护启动前就存在的进程
    if [ $(( ROUND % 60 )) -eq 0 ]; then
        for _pid in $ALLP; do
            [ "$_pid" = "$$" ] && continue
            IFS= read -r _comm < "/proc/$_pid/comm" 2>/dev/null || continue
            fjg_suspect_comm "$_comm" || continue
            fjg_check_new "$_pid"
        done
    fi
    sleep "$PROC_INTERVAL"
done
