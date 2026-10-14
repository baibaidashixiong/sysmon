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

TOP GPU  (engine busy, last 1s)
  PID          GPU%       VRAM  COMMAND
  14594        99.0       1.6G  DyingLightGame
  1484          0.7     101.7M  plasmashell
```

## 特性

- **系统总览**：CPU 总体/每核占用、PSI 压力、内存与 swap、显存 VRAM/GTT、
  磁盘读写、CPU/GPU/NVMe 温度、按 CPU 排序的进程列表。
- **TOP GPU**：按 GPU 引擎占用排序的进程列表，同时给出每个进程占用的显存；
  没有引擎计数器时自动改为按显存排序。
- **TOP MEM**：按 RSS 排序的进程列表（附各自 swap）；进程模式还会给出
  RSS 构成（anon/shared/private）、PSS、swap，以及 virt/peak/data/stack/exe/lib/pte 明细。
- **GPU 引擎细分**：系统模式增加 `ENGINE` 行、进程模式列出各引擎占用，
  可区分 3D 渲染、视频解码、视频编码、显存拷贝，直接判断软解还是硬解。
- **网络**：系统模式显示各网卡的实时收发速率（自动列出有流量的网卡），
  进程模式显示该进程的套接字数量与 TCP 连接状态。
- **可展开的内存明细**：`-m` 展开 free/cached/slab/anon/mapped/active/
  commit/swap IO 等完整 `/proc/meminfo` 视图，进程模式同时给出 PSS 构成。
- **进程模式**：按名字或 PID 自动识别进程，显示每线程 CPU、RSS、swap、
  该进程独占的 VRAM/GTT/evicted 显存、GPU 引擎占用率、进程磁盘 I/O。
- **易读**：百分比按阈值着色（绿 <50%、黄 50-75%、红 75-90%、红底 >=90%），
  关键指标带进度条。
- **不闪烁**：整帧一次性输出，使用 DEC 2026 同步刷新与备用屏幕缓冲区，
  每秒刷新也不会闪。
- **自适应终端**：按窗口宽高裁剪内容和进程行数，每行清除到行尾，
  窄窗口或小窗口下也不会出现残影、串行。
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
| `-G` | 不显示 TOP GPU 进程表（进程多、想省开销时可用） |
| `-m` | 展开内存明细（系统模式 3 行 meminfo 分解；进程模式加 PSS 构成） |
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
| `MEM` | 已用/总量（百分比保留一位小数），swap 使用比例，以及末尾的实时变化速率 `+2.5M/s`（增长变黄/红，下降为绿色） |

加上 `-m` 后，系统模式额外显示三行：

```
MEM   free 1.43G   buffers 146M   cached 5.39G   shmem 302M   slab 1.06G (reclaimable 762M)   pagetables 68.1M
MEM   anon 4.81G   mapped 929M   active 4.91G   inactive 5.63G   dirty 1.4M   writeback 0K
MEM   commit 39.2G / 26.8G (146%)   swapcached 438M   swap in/out 0.0B/s / 0.0B/s
```

`commit` 超过 100% 表示内存被超额承诺（常见于 Steam/游戏场景），
`swap in/out` 持续非零说明已经开始用交换分区换页。
| `GPU VRAM` | 显存占用；`GTT` 是 GPU 溢出到系统内存的部分 |
| `busy` | GPU 整体利用率（驱动支持时显示） |
| `DISK` | 根分区所在磁盘的实时读写速率 |
| `NET` | 各网卡的实时收发速率；只显示有流量的网卡，默认路由网卡空闲时也会显示 |
| `TOP GPU` | 按 GPU 引擎占用排序的前 5 个进程，附各自的显存占用；无引擎计数器时按显存排序 |
| `TOP MEM` | 按 RSS 排序的前几个进程，并列出各自的 swap 用量 |
| `UPTIME` | 进程已运行时间（`45s` / `12m` / `2h13m` / `3d4h`），来自 `/proc/<pid>/stat` 的 starttime，无需额外权限 |
| `ENGINE` | 各 GPU 引擎的整机占用（3D、视频解码、编码等），仅显示有活动的引擎 |

### 进程模式

| 字段 | 含义 |
| --- | --- |
| `CPU` | 进程总占用（可超过 100%，多核并行） |
| `THREADS` | 按 CPU 排序的线程列表，`100%` = 占满一个核 |
| `engine` | 该进程占用的 GPU 引擎时间比例（fdinfo 统计，amdgpu 为 gfx，i915 为 render） |
| `engines` | 该进程各 GPU 引擎的占用明细，如 `gfx 3%`、`dec 62%` |

> GPU 引擎占用按"两次采样之间、同一个 GPU 设备 + 同一客户端 + 同一引擎"的计数差
> 计算。进程刚创建的新 GPU 客户端要等下一个采样周期才有基线，因此那一帧会先显示
> idle，而不是把历史累计值当成本秒的用量（否则会瞬间出现几千个百分点）。
| `VRAM` | 该进程独占显存（来自 `/proc/<pid>/fdinfo`），括号内为占显卡总显存比例 |
| `evicted` | 被换出到系统内存的显存（持续增长说明显存不够） |
| `RSS` / `swap` | 物理内存 / 已换出的进程内存 |
| `NET` | 该进程持有的套接字总数，以及其中 TCP 已建立、监听和 UDP 的数量 |
| `MEM` | 该进程 `rss`（含 anon/shared/private 构成）、`pss`、`swap`；下一行是 `virt`/`peak`/`data`/`stack`/`exe`/`lib`/`pte` 明细 |
| `uptime` | 该进程已运行时间，可用于区分"刚启动"和"跑了很久"的进程 |

> `COMMAND` / `PROC` / `THREADS` 里的名字来自 `/proc/<pid>/comm`，
> 这是程序自己可以改的标签（最长 15 字符），并不一定是可执行文件名。
> Wine/Proton 会把游戏进程命名为 `GameThread`，浏览器会给线程起
> `Compositor`、`Renderer` 之类的名字。脚本在名字与可执行文件或命令行里的
> `.exe` 不一致时会用方括号补上真实程序，例如
> `GameThread [Cyberpunk2077.exe]`。

## 瓶颈判读

- `VRAM` 接近 100% 且 `GTT`、`evicted` 持续上涨 → 显存溢出，材质在内存间搬移，
  表现为顿卡（城市天际线类游戏常见）。
- `engine` 接近 100% → GPU 已满载，降低分辨率/画质最有效。
- 某个线程接近 100%、整机 `idle` 很高 → 单核瓶颈，加核心和降分辨率都无用，
  要减少主线程负担（视距、AI 密度等）。
- `PSI cpu full > 0` 或 `MEM` 接近 100% → 系统级资源竞争，先关后台程序。

## 软解 / 硬解怎么看

播放视频时用 `sysmon.sh <播放器或 PID>` 看进程模式，或直接看系统模式的 `ENGINE` 行：

- 视频解码引擎有占用 → 该进程在用 **GPU 硬解**。常见名称：
  `dec`、`uvd`、`vcn`（AMD），`video`、`video-enhance`（Intel）。
- 引擎列表里没有视频引擎、而进程 CPU 很高 → **软解**。
- 其他引擎：`gfx`/`render` 是 3D 渲染，`enc`/`vce`/`vcn-enc` 是视频编码，
  `jpeg` 是图片解码，`copy`/`dma` 是显存拷贝。

引擎计数来自 DRM fdinfo，只有当进程真的向该引擎提交过任务时才会出现，
所以"没有视频引擎"本身就是软解的证据（而不是统计缺失）。

本机实测对照（Radeon R7 240，1080p H.264，ffmpeg 循环播放）：

| 解码方式 | 进程 CPU | ENGINE |
| --- | --- | --- |
| VAAPI 硬解 | 2% | `dec` 持续有占用 |
| 软解 | 14% | 无视频引擎 |

## 通用性说明

- 脚本按 Linux 标准接口编写（`/proc`、`/sys`、hwmon、DRM fdinfo），
  在常见的 x86_64 与 LoongArch 等平台均可运行。
- 显存/引擎统计依赖内核的 DRM fdinfo（Linux 5.19+ 完善）；旧内核会自动显示 `n/a`。
- 温度传感器按名称探测（`cpu_hwmon`/`coretemp`/`k10temp`；`amdgpu`/`radeon`/`nouveau`/`i915`/`xe`），
  名字不在列表内时会显示 `--`。
- NVIDIA 通过 `nvidia-smi` 读取整卡显存和利用率；单进程显存无法从 sysfs 获取，
  此时进程模式的 `VRAM` 显示为 `no DRM client found`。
- 若所有 DRM 卡都没有 `mem_info_vram_total`（常见于旧 `radeon` 驱动、vfio
  直通或非主显示设备），显存会显示为 `VRAM n/a` 并附上显卡型号，而不再是
  容易误解的 `0.0B/0.0B`。在目标机器上可用
  `ls /sys/class/drm/card*/device/mem_info_vram_*` 与
  `lspci -k -s <BDF>`（看 Kernel driver 是 amdgpu 还是 radeon）确认原因。
- 内核不提供单进程网络流量统计（`/proc/<pid>/net/dev` 是整个网络命名空间的），
  所以进程模式只能给出套接字与连接状态；要看每进程带宽可用 `nethogs`、
  `bandwhich`，按连接排查可用 `ss -tp`。
- 非 Linux 系统（macOS/BSD/Windows）不支持：没有对应的 `/proc` 接口。

## 开发

```bash
make check      # 语法检查 + 冒烟测试
```

## 性能

1 秒刷新时，整机模式自身约占用 0.14 秒 CPU/帧（约单核 14%），
进程模式约 0.04 秒/帧。开销主要在每秒扫描 `/proc/<pid>/stat` 和所有
DRM fdinfo；脚本已做批量扫描、结果缓存和无子进程渲染。

想进一步降低开销可以用 `-i 2` 放慢刷新，或用 `-G` 关闭 GPU 进程表。

## License

MIT，见 [LICENSE](LICENSE)。
