# FJGuard

防格机的模块。

有人——或者某个脚本——想把你手机清空的时候，它试着拦一下。拦不住的，把文件补回来。

## 干什么

| 做 | 具体 |
|---|---|
| 拦 | `dd of=/dev/block`、`mkfs`、`rm -rf /data`、删锁屏库、恢复出厂广播、`pm clear` 系统包 |
| 补 | 删掉 `/data/system` 下的关键文件，一秒左右写回去，权限和 SELinux 标签一起还原 |
| 查 | 每 90 秒过一遍，被清空或写坏的也能发现 |
| 救 | 开机时系统还没起来，先把锁屏库、包管理库补上，免得卡在开机或者解不开锁 |
| 扛 | 守护进程被杀会自己回来；自己的脚本加 `chattr +i`，root 也删不掉 |

## 装

Magisk、KernelSU、APatch 都行，刷 zip 就可以：

    su -c 'magisk --install-module /sdcard/Download/FJGuard-v1.0.4.zip'

不重启也生效，重启后开机自愈那层才接上。

## 用

    sh /data/adb/modules/fjguard/bin/ctl.sh status      # 看状态
    sh /data/adb/modules/fjguard/bin/ctl.sh selftest    # 自检，正常是 8 通过
    sh /data/adb/modules/fjguard/bin/ctl.sh blocked     # 今天拦了什么
    sh /data/adb/modules/fjguard/bin/ctl.sh allow       # 放行 60 秒
    sh /data/adb/modules/fjguard/bin/ctl.sh off         # 关掉

刷机、跑清理脚本之前先 `allow`，不然它会把你的命令当成攻击掐掉。

## 几个坑

- 它只看命令行。`sh -c "一整段脚本"` 这种写法，整段都在命令行里，里面带删数据的命令就会被判成攻击。
- 半秒扫一次。跑得飞快、马上就退的命令可能漏掉，剩下的靠回滚兜着。
- 回滚用的是建基线那一刻的内容。改过锁屏密码之后跑一次 `ctl.sh baseline`。
- 自带程序直接往块设备写、或者专门研究过这个模块的人，挡不住。它是减速带，不是保险箱。

## 配置

改 `/data/adb/fjguard/guard.conf`，然后重启守护。

扫描间隔、要不要管 `/sdcard`、要不要发通知，都在里面。

## 兼容性

Magisk 上实测过（alpha 30600，Android 13，Realme RMX3031）。

KernelSU 和 APatch 是按标准模块格式写的，没实机刷过。装上要是有问题，提 issue 的时候带上机型和 `ctl.sh status` 的输出。

更细的表在 [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)。

## 自己构建

    bash build.sh

产物在 `dist/`。

## 许可

MIT

---

Not a Chinese reader? It's an anti-wipe module for rooted Android: kills destructive commands, restores deleted `/data/system` files within a second, repairs them before boot. Magisk / KernelSU / APatch, MIT.
