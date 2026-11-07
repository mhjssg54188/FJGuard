#!/system/bin/sh
# 建立 / 刷新关键文件快照基线
# 用法: snapshot.sh [--init|--refresh|--force]
_BD=$(dirname "$0")/common.sh
[ -f "$_BD" ] || _BD=/data/adb/fjguard/rt/common.sh
[ -f "$_BD" ] || _BD=/data/adb/modules/fjguard/bin/common.sh
. "$_BD"

fjg_targets() {
    for _f in \
        /data/system/locksettings.db \
        /data/system/locksettings.db-wal \
        /data/system/locksettings.db-shm \
        /data/system/packages.xml \
        /data/system/packages.list \
        /data/system/packages-backup.xml \
        /data/system/device_policies.xml \
        /data/system/appops.xml \
        /data/adb/magisk.db \
        /data/adb/magisk/util_functions.sh \
        /data/adb/magisk/boot_patch.sh \
        /data/adb/pif.prop ; do
        [ -f "$_f" ] && echo "$_f"
    done
    for _f in /data/system/users/*.xml /data/system/users/*/*.xml; do
        [ -f "$_f" ] && echo "$_f"
    done
    for _f in /data/adb/post-fs-data.d/*.sh /data/adb/service.d/*.sh /data/adb/boot-completed.d/*.sh; do
        [ -f "$_f" ] && echo "$_f"
    done
    if [ "${WATCH_MODULES:-1}" = "1" ]; then
        for _m in /data/adb/modules/*/; do
            [ -d "$_m" ] || continue
            _id=$(basename "$_m")
            case "$_id" in
                fjguard) ;;
            esac
            for _f in "$_m"module.prop "$_m"post-fs-data.sh "$_m"service.sh \
                      "$_m"boot-completed.sh "$_m"uninstall.sh "$_m"customize.sh; do
                [ -f "$_f" ] && echo "$_f"
            done
        done
    fi
}

fjg_snapshot_build() {
    fjg_init_dirs
    _list=$(fjg_targets)
    _new="$INDEX.new"
    : > "$_new" 2>/dev/null
    _cnt=0
    _missing_ok=0
    for _p in $_list; do
        _dst="$MIRROR$_p"
        mkdir -p "$(dirname "$_dst")" 2>/dev/null
        [ -f "$_dst" ] && chattr -i "$_dst" 2>/dev/null
        if cp -f "$_p" "$_dst" 2>/dev/null; then
            _meta=$(fjg_meta "$_p")
            IFS='|' read -r _mode _uid _gid _ctx _sz _sha <<EOF
$_meta
EOF
            printf '%s|%s|%s|%s|%s|%s|%s\n' "$_p" "$_mode" "$_uid" "$_gid" "$_ctx" "$_sz" "$_sha" >> "$_new"
            _cnt=$(( _cnt + 1 ))
            [ "${IMMUTABLE:-1}" = "1" ] && chattr +i "$_dst" 2>/dev/null
        else
            _missing_ok=$(( _missing_ok + 1 ))
        fi
    done
    if [ "$_cnt" -ge 5 ]; then
        mv -f "$_new" "$INDEX" 2>/dev/null
        date +%s > "$STATE/baseline.ts" 2>/dev/null; fjg_now > "$STATE/baseline.time" 2>/dev/null
        fjg_log baseline built "共 $_cnt 项（跳过 $_missing_ok）"
        return 0
    fi
    rm -f "$_new" 2>/dev/null
    fjg_log baseline abort "有效项仅 $_cnt，保留旧基线"
    return 1
}

fjg_mirror_out() {   # 异地镜像：/data/local 与 /sdcard，便于格机后从外部恢复
    mkdir -p "$STASH" "$SDMIR" 2>/dev/null
    cp -f "$INDEX" "$STASH/baseline.idx" 2>/dev/null
    cp -f "$INDEX" "$SDMIR/baseline.idx" 2>/dev/null
    cp -rf "$MIRROR" "$STASH/" 2>/dev/null
    cp -rf "$MIRROR" "$SDMIR/" 2>/dev/null
    cp -f "$CFG" "$STASH/guard.conf" 2>/dev/null
    cp -f "$CFG" "$SDMIR/guard.conf" 2>/dev/null
    echo "恢复方法：cp -rf $SDMIR/root/* /（或用 ctl.sh restore --all）" > "$SDMIR/如何恢复.txt" 2>/dev/null
    return 0
}

fjg_maybe_refresh() {   # 基线过期（>12h）或缺失时刷新
    _now=$(date +%s)
    _ts=$(cat "$STATE/baseline.ts" 2>/dev/null)
    if [ ! -f "$INDEX" ] || [ -z "$_ts" ]; then
        fjg_snapshot_build && fjg_mirror_out
        return 0
    fi
    if [ $(( _now - _ts )) -gt 43200 ]; then
        fjg_snapshot_build && fjg_mirror_out
        return 0
    fi
    return 0
}

case "${1:---refresh}" in
    --init)
        fjg_snapshot_build
        fjg_mirror_out
        fjg_log baseline init "安装初始化完成"
        ;;
    --refresh)
        fjg_snapshot_build && fjg_mirror_out
        ;;
    --maybe)
        fjg_maybe_refresh
        ;;
    --force)
        rm -f "$INDEX" 2>/dev/null
        fjg_snapshot_build && fjg_mirror_out
        ;;
    *)
        echo "用法: snapshot.sh [--init|--refresh|--maybe|--force]"
        exit 2
        ;;
esac
exit 0
