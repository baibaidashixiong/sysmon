# sysmon

Linux 终端里的实时资源监视脚本：一条命令看系统全貌，或聚焦到某个进程。
单文件、纯 bash、无需 root、不装任何依赖。

```
sysmon 15:52:17  up 0d5h5m  load 2.79 3.03 3.01
CPU   ####........ 21.7% (1.74/8)   idle 78.2%  iowait 0.0%   PSI 0.24%/0.00%
      cores 12.5 12.5 8.6 9.6 27.8 25.9 17.3 62.5
MEM   #########... 78%   12.1G / 15.5G used   avail 3.4G   swap 1.1G / 19.0G (5%)
GPU   ###########. VRAM 92%   1.9G / 2.0G   GTT 559.7M (7%)   temp 58C
DISK  sda   read 0.0B/s   write 0.0B/s
TEMP  CPU 42C   GPU 58C   NVMe 54C

TOP CPU  (last 1s)
  PID          CPU%        RSS  COMMAND
  14594       156.7       2.5G  DyingLightGame
```

## 特性

- **系统总览**：CPU 总体/每核占用、PSI 压力、内存与 swap、显存 VRAM/GTT、
  磁盘读写、CPU/GPU/NVMe 温度、按 CPU 排序的进程列表。
- **进程模式**：按名字或 PID 自动识别进程，显示每线程 CPU、RSS、swap、
  该进程独占的 VRAM/GTT/evicted 显存、GPU 引擎占用率、进程磁盘 I/O。
- **易读**：百分比按阈值着色（绿 <50%、黄 50-75%、红 75-90%、红底 >=90%），
  关键指标带进度条。
- **不闪烁**：整帧一次性输出，使用 DEC 2026 同步刷新与备用屏幕缓冲区，
  每秒刷新也不会闪。
- **零依赖**：只需要 Linux 的 `/proc` 和 `/sys`，不需要安装任何包。

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 系统 | Linux（依赖 `/proc`、`/sys`；macOS / Windows 不支持） |
| Shell | bash >= 4.3 |
| 可选工具 | `nvidia-smi`（NVIDIA 显存）、`findmnt`/`lsblk`（定位根分区设备，缺失时可回退解析） |

## 安装

```bash
git clone <this-repo> ~/sysmon   # 或直接把目录放好
ln -sfn ~/sysmon/sysmon.sh ~/sysmon.sh    # 可选：方便直接调用
```

或者：

```bash
make install          # 安装到 ~/.local/bin/sysmon
```

## 用法

```bash
sysmon.sh                        # 系统总览，实时刷新
sysmon.sh DyingLightGame         # 自动识别进程（按名字匹配，选 RSS 最大者）
sysmon.sh 14594                  # 按 PID 监控
sysmon.sh -i 2 -n 10 firefox     # 2 秒刷新，共 10 次后退出
sysmon.sh -p                     # 纯文本（无颜色、无进度条）
sysmon.sh -c | less -R           # 管道输出时强制颜色
```

| 选项 | 说明 |
| --- | --- |
| `-i SECONDS` | 刷新间隔，默认 1 秒（支持小数） |
| `-n COUNT` | 刷新 COUNT 次后退出，默认一直运行到 Ctrl-C |
| `-p` | 纯文本输出，便于记日志 |
| `-c` | 强制彩色输出（非终端时默认关色） |
| `-v` | 打印版本 |
| `-h` | 帮助 |

环境变量 `NO_COLOR` 非空时自动关闭颜色。

## 字段说明

### 系统模式

| 字段 | 含义 |
| --- | --- |
| `CPU busy` | 整机 CPU 占用（100% = 一个核；括号内为等价核数/总核数） |
| `cores` | 每个逻辑核的占用率 |
| `PSI` | `/proc/pressure` 的 `some/full` 平均值，反映任务被真实阻塞的时间比例 |
| `MEM` | 已用内存/总量，括号内为 swap 使用比例 |
| `GPU VRAM` | 显存占用；`GTT` 是 GPU 溢出到系统内存的部分 |
| `busy` | GPU 整体利用率（驱动支持时显示） |
| `DISK` | 根分区所在磁盘的实时读写速率 |

### 进程模式

| 字段 | 含义 |
| --- | --- |
| `CPU` | 进程总占用（可超过 100%，多核并行） |
| `THREADS` | 按 CPU 排序的线程列表，`100%` = 占满一个核 |
| `engine` | 该进程占用的 GPU 引擎时间比例（fdinfo 统计，amdgpu 为 gfx，i915 为 render） |
| `VRAM` | 该进程独占显存（来自 `/proc/<pid>/fdinfo`），括号内为占显卡总显存比例 |
| `evicted` | 被换出到系统内存的显存（持续增长说明显存不够） |
| `RSS` / `swap` | 物理内存 / 已换出的进程内存 |

## 瓶颈判读

- `VRAM` 接近 100% 且 `GTT`、`evicted` 持续上涨 → 显存溢出，材质在内存间搬移，
  表现为顿卡（城市天际线类游戏常见）。
- `engine` 接近 100% → GPU 已满载，降低分辨率/画质最有效。
- 某个线程接近 100%、整机 `idle` 很高 → 单核瓶颈，加核心和降分辨率都无用，
  要减少主线程负担（视距、AI 密度等）。
- `PSI cpu full > 0` 或 `MEM` 接近 100% → 系统级资源竞争，先关后台程序。

## 通用性说明

- 脚本按 Linux 标准接口编写（`/proc`、`/sys`、hwmon、DRM fdinfo），
  在常见的 x86_64 与 LoongArch 等平台均可运行。
- 显存/引擎统计依赖内核的 DRM fdinfo（Linux 5.19+ 完善）；旧内核会自动显示 `n/a`。
- 温度传感器按名称探测（`cpu_hwmon`/`coretemp`/`k10temp`；`amdgpu`/`radeon`/`nouveau`/`i915`/`xe`），
  名字不在列表内时会显示 `--`。
- NVIDIA 通过 `nvidia-smi` 读取整卡显存和利用率；单进程显存无法从 sysfs 获取，
  此时进程模式的 `VRAM` 显示为 `no DRM client found`。
- 非 Linux 系统（macOS/BSD/Windows）不支持：没有对应的 `/proc` 接口。

## 开发

```bash
make check      # 语法检查 + 冒烟测试
```

## License

MIT，见 [LICENSE](LICENSE)。
