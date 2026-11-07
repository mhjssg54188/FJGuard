# 更新日志

## v1.0.3

- **兼容性**：busybox 探测扩展为 Magisk / KernelSU / APatch / 系统自带多路径，全部缺失时退回 `/system/bin` 的 toybox（纯 KSU 无 Magisk 环境可运行）
- **兼容性**：安装时识别 root 管理器（`MAGISK_VER` / `KSU` / `APATCH` 环境变量优先），全局自愈钩子仅在 Magisk 下安装
- **兼容性**：`post-fs-data.sh` / `service.sh` 的 `MODDIR` 增加兜底，管理器以非标准方式执行脚本时不会失效
- **兼容性**：自我保护的关键路径增加 `/data/adb/ksu`、`/data/adb/ap`
- **修复**：`uninstall.sh` 不再硬编码 Magisk busybox 路径
- **修复**：日志中的命令行换行会破坏一行一条的结构，现已压平
- **仓库**：新增 `LICENSE`(MIT)、`build.sh`、GitHub Actions、`docs/COMPATIBILITY.md`、`update.json.example`、`.gitignore`

## v1.0.2

- **修复**：完整性巡检不认识 Android 13 的 ABX 二进制 XML，会把正常文件判为损坏并反复重写
- **修复**：还原引擎读取基线索引时字段错位（把权限位当属主），现已修正，并增加"污染索引"兜底与还原后属性校验
- **修复**：`argv[0]`（如 `/system/bin/sh`）会被当成攻击目标，导致把 `sh -c` 执行的正常运维命令误杀
- **修复**：`/system/*`、`/vendor/*` 等只读分区普通路径不再纳入拦截（误报源）
- **修复**：`chmod/chown/chattr` 批量规则只认 `-R`，避免 `read -r` 之类的误判
- **修复**：`cp` 备份 `/data/system` 到 `/sdcard` 不再被判为覆盖攻击
- **修复**：`onchange.sh` 在状态目录未建立时 `exec` 重定向失败会直接退出
- **改进**：同进程同规则 5 秒内只处置一次；杀父进程仅限"执行 .sh 的 shell"，不牵连 `sh -c` 外壳

## v1.0.1

- 基线刷新改由 `--maybe`（12 小时节流），减少开机写盘
- 安装不再覆盖用户已有配置

## v1.0.0

- 首个版本：五层防护（开机自愈 / 指令拦截 / 事件回滚 / 完整性巡检 / 双守护自愈）
- 基线快照 + `chattr +i` 自保护 + 异地镜像（`/data/local` 与 `/sdcard`）
- `ctl.sh` 管理命令：status / selftest / log / blocked / allow / logonly / on / off / baseline / restore
