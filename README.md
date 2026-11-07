# FJGuard · 防格机全防模块

**给 root 用户的多层"防格机 / 防砖"防护模块**：当脚本或模块试图清空数据、删除关键系统库、格式化分区时，它当场拦截，并把删掉的文件秒级补回来；即使已经搞坏了，也能在开机阶段（系统起来之前）自动修复。

> A multi-layer anti-wipe / anti-brick Magisk-style module for Android root users. Blocks destructive commands (`rm -rf /data`, `dd of=/dev/block`, factory-reset, …), restores deleted `/data/system` databases within ~1 s, and repairs them during `post-fs-data` before the system boots.

| 项目 | 说明 |
|---|---|
| 版本 | v1.0.4 |
| 适用 | Android 11+（13+ 的 ABX 二进制 XML 已适配），Magisk / KernelSU / APatch |
| 依赖 | 无需 Xposed、无需独立二进制；仅 shell + toybox + inotify |
| 许可 | MIT |

---

## 一、它防什么

| 层 | 机制 | 拦截对象 |
|---|---|---|
| **L0 开机自愈** | `post-fs-data`（system_server 之前）补回缺失/损坏的关键文件，实测 ~177 ms | 锁屏库/包管理库被删导致的"无法解锁、开机卡死" |
| **L1 指令拦截** | 每 0.6 s 扫描新进程，命中即 `SIGSTOP→SIGKILL`（并终止调用它的脚本） | `dd of=/dev/block/*`、`mkfs/mke2fs/wipefs`、`rm -rf /data`、删锁屏/包管理库、`MASTER_CLEAR`、`pm clear` 系统包、`chmod -R`、写坏关键库 |
| **L2 实时回滚** | inotify 监听 19 个目录，删除/移出事件毫秒级回写（生产实测 ~1 s） | 删除或改名 `/data/system`、`/data/adb` 下的关键文件、其它模块脚本 |
| **L3 完整性巡检** | 每 90 s 校验存在性 + SQLite 文件头 + ABX/文本 XML 结构 | 静默删除、用垃圾内容覆盖 |
| **L4 双守护自愈** | 两个 supervisor 互保 + 各拉起三个工作守护（实测杀掉后 33 s 内复活） | 杀进程、删脚本 |

附加：

- 运行时副本与基线用 `chattr +i` 锁定（f2fs/ext4 上 root 也删不掉；不支持时自动降级）
- 基线异地镜像到 `/data/local/fjguard_stash` 与 `/sdcard/FJGuard`，可用于灾后手工恢复
- Magisk 下额外安装 `/data/adb/{post-fs-data.d,service.d}` 自愈钩子：模块目录被整体删除也能重建

## 二、兼容性

| 管理器 | 安装 | 验证状态 |
|---|---|---|
| Magisk（含 alpha/Delta/Kitsune 等分支） | ✅ | **本机实测**（alpha 30600 / Android 13 / Realme RMX3031） |
| KernelSU（含 SukiSU Ultra、KernelSU Next 等分支） | ✅ | 按标准模块格式适配 + 无 busybox 降级验证，**未实机刷入** |
| APatch | ✅ | 同上 |

busybox 自动探测 Magisk / KernelSU / APatch 三处路径，全部缺失时退回 `/system/bin` 的 toybox，**纯 KernelSU 环境（无 Magisk）也能跑**。详见 [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)。

## 三、安装

1. 下载 `FJGuard-vX.Y.Z.zip`（**不要解压，`module.prop` 必须在 zip 根目录**）
2. 打开面具管理器 → 模块 / 安装 → 选择 zip → 重启
3. 装完立即生效（守护会当场拉起），重启后开机自愈层一并生效

命令行安装（Magisk）：

```sh
su -c 'magisk --install-module /sdcard/Download/FJGuard-v1.0.4.zip'
```

> KSU / APatch 请用各自管理器的"安装模块"功能刷入同一个 zip；包内的 `META-INF/update-binary` 只有 Magisk 会读，其他管理器忽略。

## 四、使用

安装后管理入口固定在 `/data/adb/modules/fjguard/bin/ctl.sh`（状态目录里也有一份 `/data/adb/fjguard/rt/ctl.sh`）：

```sh
su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh status'        # 状态总览
su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh selftest'      # 自检（期望 8 通过 / 0 失败）
su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh log 30'        # 事件日志
su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh blocked'       # 拦截记录
su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh allow'         # 放行 60 秒（刷机/维护前）
su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh logonly on'    # 只记录不拦截
su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh off'           # 停用
su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh baseline'      # 重建基线（改过密码后建议执行）
su -c 'sh /data/adb/modules/fjguard/bin/ctl.sh restore --all'  # 全量恢复
```

## 五、配置

`/data/adb/fjguard/guard.conf`（首次安装从 `config/guard.conf` 复制，之后不覆盖用户改动）：

| 键 | 默认 | 说明 |
|---|---|---|
| `PROC_INTERVAL` | `0.6` | 进程扫描间隔（秒，支持小数） |
| `INTEGRITY_INTERVAL` | `90` | 完整性巡检间隔（秒） |
| `IMMUTABLE` | `1` | 是否给运行时副本/基线加 `chattr +i` |
| `BLOCK_SDCARD` | `1` | 是否保护 `/sdcard` 媒体目录（照片目录任意深度都保护） |
| `BLOCK_PM_CLEAR` | `1` | 是否拦 `pm clear` 系统关键包 |
| `FREE_WARN_MB` | `1024` | `/data` 剩余空间预警阈值 |
| `LOG_MAX_KB` | `512` | 单日志文件上限 |
| `NOTIFY` | `1` | 是否发系统通知 |

## 六、工作原理与目录结构

```
/data/adb/fjguard/            # 状态目录
├── guard.conf                # 配置
├── baseline.idx              # 基线索引（路径|权限|属主|SELinux 上下文|大小|sha256）
├── baseline/root/            # 基线镜像（可 chattr +i）
├── rt/                       # 运行时副本（chattr +i，守护实际执行的就是这里）
├── run/                      # pid / 锁 / 标记
└── log/                      # events.log / blocked.log / 各守护日志
```

- `bin/snapshot.sh` 建立基线；`bin/common.sh` 提供还原、巡检、锁等公共逻辑
- `bin/procguard.sh` 是 L1：只对"新出现的进程"解析命令行（fork 少、开销低），每 60 轮做一次全量兜底
- `bin/watcher.sh` + `bin/onchange.sh` 是 L2；`bin/integrity.sh` 是 L3；`bin/supervisor.sh` 是 L4
- `post-fs-data.sh` 负责 L0，`service.sh` 负责在开机后拉起守护

## 七、误伤与边界（重要）

**误伤处理**：正常运维被拦 → `ctl.sh allow` 后 60 秒内放行；长期嫌吵 → `ctl.sh logonly on` 观察，或把 `BLOCK_SDCARD=0`。

**已知会误拦的形态**：通过 `sh -c "整段脚本"` 执行时，整段文本都在命令行里，只要包含破坏性字面量（`rm -rf /data`、`chattr`、`dd of=/dev/block` 等）就会被判为攻击。这是刻意的（格机脚本常用该形态），运维时先 `allow`。

**边界**（如实说明，不夸大）：

- 这是"速度屏障 + 自动回滚"，**不是内核级沙箱**：自带二进制直接 syscall、直接写块设备的攻击拦不住
- 极快且立即退出的命令可能落在扫描间隙（L2/L3 在结果层面兜底）
- 还原的是**基线时刻**的内容：改过锁屏密码后建议 `ctl.sh baseline` 刷新基线
- 模块本身以 root 运行，**能挡住脚本误伤与恶意模块，但挡不住已经拿到 root 且针对性研究本模块的人**

**灾后恢复**：单个文件 `ctl.sh restore <路径>`；全量 `ctl.sh restore --all`；系统已起不来时挂载 `/data`，从 `/sdcard/FJGuard/root` 拷回原路径后 `restorecon -F <路径>`。

## 八、构建与发版

```sh
bash build.sh          # 产出 dist/FJGuard-vX.Y.Z.zip（需要 zip/unzip/zipinfo）
```

- 仓库自带 GitHub Actions（`.github/workflows/build.yml`）：语法检查 + 构建 + 结构校验 + 上传产物
- 想接入 Magisk 模块仓库的在线更新：复制 `update.json.example` 为 `update.json` 填好地址，并在 `module.prop` 里加一行 `updateJson=https://raw.githubusercontent.com/<user>/FJGuard/main/update.json`

## 九、贡献

- 报兼容性结果请附：管理器名称与版本、Android 版本、机型、`ctl.sh status` 与 `selftest` 输出（见 [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) 的验证清单）
- 新攻击手法（想拦的命令形态）欢迎提 Issue，附上命令行样本即可，规则集中在 `bin/procguard.sh` 的 `fjg_match()`
- 提交前请至少跑一遍 `ctl.sh selftest`，并确认 `sh -n` 通过

## 十、许可

[MIT](LICENSE)

---

## English summary

FJGuard is a multi-layer anti-wipe / anti-brick module for rooted Android devices (Magisk, KernelSU, APatch).

Five layers: **L0** repairs critical `/data/system` databases during `post-fs-data` (before `system_server`, ~177 ms); **L1** scans new processes every 0.6 s and kills destructive commands (`dd of=/dev/block`, `mkfs`, `rm -rf /data`, factory-reset broadcasts, …); **L2** restores deleted watched files via inotify within ~1 s; **L3** verifies file structure (SQLite header, ABX/text XML) every 90 s; **L4** runs two mutually-supervising supervisors that revive three worker daemons.

No Xposed, no native binaries — plain shell, toybox and `inotifyd`. Works without busybox (falls back to `/system/bin`), auto-detects Magisk/KernelSU/APatch paths, and uses `chattr +i` for self-protection where supported.

Control it with `ctl.sh status|selftest|allow|logonly|off|baseline|restore`. Before maintenance work (flashing, cleanup scripts) run `ctl.sh allow` to grant a 60-second window.

**It is a speed bump plus automatic rollback, not a kernel sandbox**: a targeted native payload writing block devices directly, or an attacker who has root and studies this module, can still get through. Also note that commands sent via `sh -c "<script>"` are matched on the full command line, so any destructive literal inside them is treated as an attack.
