#!/system/bin/sh
# FJGuard 自愈钩子（安装时复制到 /data/adb/service.d/）
# 作用：模块被删后重建的模块不会自动跑 service.sh，这里补拉守护

ENF=/data/local/fjguard_stash/.enabled
[ -f "$ENF" ] || exit 0
[ -f /data/adb/fjguard/DISABLED ] && exit 0

MOD=/data/adb/modules/fjguard
RT=/data/adb/fjguard/rt

if [ -f "$MOD/bin/common.sh" ]; then
    . "$MOD/bin/common.sh"
    fjg_init_dirs
    [ -f "$RT/supervisor.sh" ] || fjg_sync_rt "$MOD/bin"
fi

[ -f "$RT/supervisor.sh" ] || exit 0
if [ -f /data/adb/fjguard/run/supervisor_A.pid ]; then
    _p=$(cat /data/adb/fjguard/run/supervisor_A.pid 2>/dev/null)
    kill -0 "$_p" 2>/dev/null && exit 0
fi
nohup "$RT/supervisor.sh" A >>/data/adb/fjguard/log/supervisor.log 2>&1 &
exit 0
