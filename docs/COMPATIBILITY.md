# 兼容性说明

## 管理器支持矩阵

| 管理器 | 安装 | 模块脚本执行 | 全局钩子 `/data/adb/{post-fs-data.d,service.d}` | busybox | 验证状态 |
|---|---|---|---|---|---|
| **Magisk**（官方 / alpha / Delta / Kitsune 等分支） | ✅ `customize.sh` | ✅ `post-fs-data.sh` / `service.sh` | ✅ 会执行 → 安装时写入自愈钩子 | `/data/adb/magisk/busybox` | **本机实测**（alpha 30600 / Android 13 / Realme RMX3031） |
| **KernelSU**（含 SukiSU Ultra、KernelSU Next 等分支） | ✅ `customize.sh`（读 `$MODPATH`、`$KSU`） | ✅ 标准模块脚本 | ⚠️ 不保证执行 → **安装时跳过**，核心防护不依赖 | `/data/adb/ksu/bin/busybox` | 按标准格式适配 + 无 busybox 环境降级验证；**未实机刷入验证** |
| **APatch** | ✅ `customize.sh` | ✅ 标准模块脚本 | ⚠️ 不保证执行 → **安装时跳过** | `/data/adb/ap/bin/busybox` | 同上；**未实机刷入验证** |

`META-INF/com/google/android/update-binary` 只有 Magisk 管理器会读，KernelSU / APatch 忽略它，不影响安装。

## 运行时依赖

脚本里 `$BB` 按下列顺序探测，全部缺失时退回 `/system/bin` 的 toybox 工具（不需要任何 busybox）：

```
/data/adb/magisk/busybox → /data/adb/ksu/bin/busybox → /data/adb/ap/bin/busybox
→ /data/adb/apatch/bin/busybox → /system/bin/busybox → /system/xbin/busybox → （空，走 PATH）
```

用到的系统工具（Android 7+ toybox 自带）：`awk cut df grep head ls lsattr nice nohup stat tr find chattr chcon restorecon inotifyd`。
这些命令在"无 busybox 环境"模拟测试中已逐项确认可用，快照/巡检/规则匹配全部正常。

由于不依赖任何管理器自带命令，**换 root 管理器不需要改代码**；只有 `/data/adb/{post-fs-data.d,service.d}` 这层"模块被删后可重建"的加强功能是 Magisk 专属。

## Android 版本

- **Android 11+**：推荐。`android_see` 无关，本模块只用 shell + inotify。
- **Android 13+**：`/data/system/*.xml` 可能是 **ABX 二进制 XML**，模块已适配（同时识别 ABX 与文本 XML）。
- **Android 10 及以下**：理论可用，未验证；`/data/system` 布局与 SELinux 标签差异可能需要在 `bin/snapshot.sh` 里补充文件清单。
- **f2fs / ext4**：`chattr +i` 自保护在 f2fs 上实测生效（root 也删不掉）；不支持 immutable 的文件系统会自动降级为普通文件（`IMMUTABLE=0` 也可手动关闭）。

## 已验证的测试项

沙箱自动化（59 项，全部通过）：

- 基线快照（文件清单、权限/属主/SELinux 上下文、immutable 标记）
- 还原引擎（权限、属主、上下文恢复；污染索引的兜底）
- 完整性判定（SQLite 文件头、ABX 二进制 XML、文本 XML、WAL 边车文件）
- 规则分类（16 组攻击样本 + 12 组误报回归）
- inotify 事件回滚
- 实机拦截（进程终止 + 落日志）
- 守护生命周期（双 supervisor 互保、子守护拉活）

生产态实测：拦截落日志并终止进程、删除后约 1 秒内回写、杀守护后 33 秒内复活、开机自愈脚本 177ms。

## 想帮忙验证其他管理器？

按这个清单跑一遍，把结果提到 Issue 即可：

1. 刷入 zip，观察安装日志是否显示正确的 root 管理器与基线条数
2. `su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh selftest'` → 期望 8 通过 / 0 失败
3. `ctl.sh status` → 5 个守护均为"运行中"
4. 拦截测试：`sh -c 'sleep 30 # of=/dev/block/by-name/userdata'` 应被立即终止，`ctl.sh blocked` 有 `DD_BLOCK` 记录
5. 回滚测试：删除 `/data/system/dropbox` 下任意文件之外的被监控文件（建议按 `bin/snapshot.sh` 清单选一个不关键的），确认 1 秒内回写
6. 重启一次，确认开机后 `ctl.sh status` 仍正常、`/data/system/locksettings.db` 属主为 `system:system`
