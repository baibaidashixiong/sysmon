#!/usr/bin/env bash
# sysmon - live system / per-process resource monitor for Linux
#
#   sysmon.sh                    system overview (CPU, RAM, GPU, disk, temps)
#   sysmon.sh firefox            focus a process by name (auto-resolve PID)
#   sysmon.sh -i 2 14594         focus a PID, 2s refresh
#
# Sources: /proc, /sys (DRM sysfs + per-process fdinfo), hwmon, /proc/pressure.
# Requirements: Linux, bash >= 4.3.
set -u
shopt -s extglob
export LC_ALL=C
VERSION="0.4.0"

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
  echo "sysmon: bash 4.3+ required (found $BASH_VERSION)" >&2
  exit 1
fi
if [[ ! -r /proc/stat || ! -d /proc/self ]]; then
  echo "sysmon: Linux /proc is required; '$(uname -s)' is not supported" >&2
  exit 1
fi

INTERVAL=1
COUNT=0
TARGET=""
COLOR_MODE=auto
BARS=1
GPU_TOP=1
CLK_TCK=$(getconf CLK_TCK 2>/dev/null || echo 100)
PAGE_KB=$(( $(getconf PAGESIZE 2>/dev/null || echo 4096) / 1024 ))

usage() {
  cat <<'EOF'
Usage: sysmon.sh [-i SECONDS] [-n COUNT] [PID|PROCESS_NAME]

  (no target)        live overview: CPU, memory, GPU, disk, temps, top procs
  PID|PROCESS_NAME   focus one process: per-thread CPU, RSS, swap, VRAM/GTT,
                     GPU engine busy, disk I/O

Options:
  -i SECONDS   refresh interval (default 1)
  -n COUNT     refresh COUNT times then exit (default: until Ctrl-C)
  -p           plain output (no colors, no bars)
  -c           force colors even when output is piped
  -G           skip the TOP GPU process table
  -v           print version
  -h           show this help

Examples:
  ~/sysmon.sh
  ~/sysmon.sh -i 2 DyingLightGame
  ~/sysmon.sh 14594
EOF
}

while getopts ":i:n:pcvGh" opt; do
  case $opt in
    i) INTERVAL=$OPTARG ;;
    n) COUNT=$OPTARG ;;
    p) COLOR_MODE=never; BARS=0 ;;
    c) COLOR_MODE=always ;;
    G) GPU_TOP=0 ;;
    v) echo "sysmon $VERSION"; exit 0 ;;
    h) usage; exit 0 ;;
    \?) echo "unknown option: -$OPTARG" >&2; usage; exit 1 ;;
    :)  echo "option -$OPTARG needs a value" >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))
TARGET=${1:-}

[[ $INTERVAL =~ ^[0-9]+([.][0-9]+)?$ && $INTERVAL != 0 ]] || { echo "bad interval: $INTERVAL" >&2; exit 1; }
[[ $COUNT =~ ^[0-9]+$ ]] || { echo "bad count: $COUNT" >&2; exit 1; }

# ---------- hardware handles ----------
GPU_DEV=""
for c in /sys/class/drm/card*/device; do
  [[ -r $c/mem_info_vram_total ]] && { GPU_DEV=$c; break; }
done
GPU_DRIVER=""
[[ -n $GPU_DEV ]] && GPU_DRIVER=$(basename "$(readlink -f "$GPU_DEV/driver" 2>/dev/null)" 2>/dev/null)
NVIDIA=0
command -v nvidia-smi >/dev/null 2>&1 && NVIDIA=1
[[ -z $GPU_DRIVER && $NVIDIA == 1 ]] && GPU_DRIVER=nvidia

find_hwmon() {
  local h
  for h in /sys/class/hwmon/hwmon*; do
    [[ -r $h/name && $(<"$h/name") == "$1" ]] && { echo "$h"; return 0; }
  done
  return 1
}
find_first_hwmon() {
  local n h
  for n in "$@"; do
    h=$(find_hwmon "$n") && { echo "$h"; return 0; }
  done
  return 1
}
read_temp() { [[ -n ${1:-} && -r $1/temp1_input ]] && echo $(( $(<"$1/temp1_input") / 1000 )); }
HWM_CPU=$(find_first_hwmon cpu_hwmon coretemp k10temp zenpower 2>/dev/null || true)
HWM_GPU=$(find_first_hwmon amdgpu radeon nouveau i915 xe 2>/dev/null || true)
HWM_NVME=$(find_first_hwmon nvme 2>/dev/null || true)

root_disk() {
  local src base
  src=$(findmnt -no SOURCE / 2>/dev/null | head -1)
  base=$(lsblk -no PKNAME "$src" 2>/dev/null | head -1)
  if [[ -z $base ]]; then
    base=${src##*/}
    case $base in
      nvme*n*p[0-9]*|mmcblk*p[0-9]*) base=${base%p[0-9]} ;;
      *[0-9]) base=${base%%[0-9]*} ;;
    esac
  fi
  echo "$base"
}
ROOT_DISK=$(root_disk)

# ---------- formatting helpers ----------
fmt_b() {
  local b=${1:-0} s="" u=1 suf=B t
  (( b < 0 )) && { s="-"; b=$(( -b )); }
  if (( b >= 1073741824 )); then u=1073741824; suf=G
  elif (( b >= 1048576 )); then u=1048576; suf=M
  elif (( b >= 1024 )); then u=1024; suf=K
  fi
  t=$(( (b * 10 + u / 2) / u ))
  printf '%s%d.%d%s' "$s" $(( t / 10 )) $(( t % 10 )) "$suf"
}
fmt_kib_b() { fmt_b $(( ${1:-0} * 1024 )); }
pct10() {
  local d=${1:-0} e=${2:-0} v
  (( e > 0 )) || { printf '0.0'; return; }
  (( d < 0 )) && d=0
  v=$(( d * 1000 / e ))
  printf '%d.%d' $(( v / 10 )) $(( v % 10 ))
}
tenths() { local v=${1:-0}; (( v < 0 )) && v=0; printf '%d.%d' $(( v / 10 )) $(( v % 10 )); }
cores2() {
  local d=${1:-0} e=${2:-0} v
  (( e > 0 )) || { printf '0.00'; return; }
  (( d < 0 )) && d=0
  v=$(( d * 100 / e ))
  printf '%d.%02d' $(( v / 100 )) $(( v % 100 ))
}
rate_b() {
  local d=${1:-0} ns=${2:-0} m=${3:-1} ms t
  (( ns > 0 )) || { printf '0'; return; }
  ms=$(( ns / 1000000 )); (( ms > 0 )) || ms=1
  t=$(( d * m * 1000 / ms )); (( t < 0 )) && t=0
  printf '%d' "$t"
}
read_mem() {
  MEM_TOTAL=0; MEM_AVAIL=0; SWAP_TOTAL=0; SWAP_FREE=0
  local k v
  while read -r k v _; do
    case $k in
      MemTotal:) MEM_TOTAL=$v ;; MemAvailable:) MEM_AVAIL=$v ;;
      SwapTotal:) SWAP_TOTAL=$v ;; SwapFree:) SWAP_FREE=$v ;;
    esac
  done < /proc/meminfo
}
psi10() {
  local f=$1 want=$2 line x
  while IFS= read -r line; do
    [[ $line == "$want "* ]] || continue
    for x in $line; do
      [[ $x == avg10=* ]] && { printf '%s' "${x#avg10=}"; return; }
    done
  done < "/proc/pressure/$f" 2>/dev/null
  printf 'n/a'
}

# ---------- snapshots ----------
declare -a PRE_CORES CUR_CORES PRE_GPU_PIDS CUR_GPU_PIDS
declare -A PRE_PROC_TICKS CUR_PROC_TICKS
declare -A PRE_GPU_VRAM CUR_GPU_VRAM PRE_GPU_GTT CUR_GPU_GTT
declare -A PRE_GPU_ENG CUR_GPU_ENG PRE_GPU_EV CUR_GPU_EV
declare -A PRE_GPU_ENGINES CUR_GPU_ENGINES
declare -A PRE_THREAD_TICKS CUR_THREAD_TICKS PRE_THREAD_COMM CUR_THREAD_COMM
for v in CPU_TOTAL CPU_IDLE CPU_IOWAIT DISK_R DISK_W PTICKS PREAD PWRITE ENGINE PV RAM PGT PEV; do
  for t in PRE CUR; do eval "${t}_${v}=0"; done
done
PRE_PENGINES=""; CUR_PENGINES=""

cpu_part() {  # $1=tag
  local line first=1
  local -n total="${1}_CPU_TOTAL" idle="${1}_CPU_IDLE" iowait="${1}_CPU_IOWAIT"
  local -n cores="${1}_CORES"
  cores=()
  while IFS= read -r line; do
    [[ $line == cpu* ]] || continue
    local name=${line%% *} rest t=0 i
    read -r -a rest <<< "$line"
    for i in 1 2 3 4 5 6 7 8; do t=$(( t + ${rest[$i]:-0} )); done
    if [[ $name == cpu ]]; then
      total=$t; idle=${rest[4]}; iowait=${rest[5]}
    else
      cores+=("$t ${rest[4]} ${rest[5]}")
    fi
  done < /proc/stat
}

disk_part() {  # $1=tag
  local -n dr="${1}_DISK_R" dw="${1}_DISK_W"
  read -r dr dw < <(awk -v d="$ROOT_DISK" '$3==d {print $6, $10; exit}' /proc/diskstats)
  dr=${dr:-0}; dw=${dw:-0}
}

snapshot_system() {  # $1=tag
  local tag=$1 p stat rest f
  cpu_part "$tag"
  disk_part "$tag"
  local -n procs="${tag}_PROC_TICKS"
  procs=()
  for p in /proc/[0-9]*; do
    IFS= read -r stat 2>/dev/null < "$p/stat" || continue
    rest=${stat#*) }
    read -r -a f <<< "$rest"
    procs[${p##*/}]=$(( ${f[11]:-0} + ${f[12]:-0} ))
  done
  local -n gpids="${tag}_GPU_PIDS" gvram="${tag}_GPU_VRAM" ggtt="${tag}_GPU_GTT"
  local -n geng="${tag}_GPU_ENG" gev="${tag}_GPU_EV"
  local -n gengines="${tag}_GPU_ENGINES"
  gpids=(); gvram=(); ggtt=(); geng=(); gev=(); gengines=()
  (( GPU_TOP )) || return 0
  local fd gp seen=" " v g e ev
  while IFS= read -r fd; do
    gp=${fd#/proc/}; gp=${gp%%/*}
    [[ $seen == *" $gp "* ]] && continue
    seen+="$gp "
    [[ -r /proc/$gp/fdinfo ]] || continue
    local engs
    read -r v g e ev engs < <(proc_gpu "$gp")
    gpids+=("$gp")
    gvram[$gp]=$v; ggtt[$gp]=$g; geng[$gp]=$e; gev[$gp]=$ev
    gengines[$gp]=$engs
  done < <(grep -l -m1 '^drm-client-id:' /proc/[0-9]*/fdinfo/* 2>/dev/null)
}

proc_gpu() {  # $1=pid -> "vram_kib gtt_kib engine_ns evicted_kib"
  awk '
    /^drm-client-id:/ {cid=$2}
    /^drm-memory-vram:/ {if(cid!="" && !(cid in v)) v[cid]=$2+0}
    /^drm-memory-gtt:/  {if(cid!="" && !(cid in g)) g[cid]=$2+0}
    /^drm-engine-/ {
      if (cid != "") {
        name=$1; sub(/^drm-engine-/, "", name); sub(/:$/, "", name)
        key=cid SUBSEP name
        if (!(key in em)) em[key]=$2+0
      }
    }
    /^amd-evicted-vram:/{if(cid!="" && !(cid in ev)) ev[cid]=$2+0}
    END{
      tv=tg=te=tev=0
      for(c in v)tv+=v[c]; for(c in g)tg+=g[c]
      for(c in ev)tev+=ev[c]
      eng=""
      for(k in em){split(k,a,SUBSEP); te+=em[k]; eng=eng a[2] ":" em[k] " "}
      printf "%d %d %d %d %s\n", tv, tg, te, tev, eng
    }
  ' /proc/"$1"/fdinfo/* 2>/dev/null
}

engine_deltas() {  # $1=prev "name:ns ..." $2=cur -> "name ns" for positive deltas
  local -A P=() C=()
  local kv name d
  for kv in $1; do P[${kv%%:*}]=${kv#*:}; done
  for kv in $2; do C[${kv%%:*}]=${kv#*:}; done
  for name in "${!C[@]}"; do
    d=$(( C[$name] - ${P[$name]:-${C[$name]}} ))
    (( d > 0 )) && printf '%s %d\n' "$name" "$d"
  done
}

snapshot_proc() {  # $1=tag $2=pid
  local tag=$1 pid=$2 stat rest t tid f c
  cpu_part "$tag"
  disk_part "$tag"
  local -n pticks="${tag}_PTICKS" pread="${tag}_PREAD" pwrite="${tag}_PWRITE"
  local -n threads="${tag}_THREAD_TICKS" comms="${tag}_THREAD_COMM"
  local -n pv="${tag}_PV" pg="${tag}_PGT" pe="${tag}_PEV" peng="${tag}_ENGINE"
  local -n pengines="${tag}_PENGINES"
  threads=(); comms=()
  IFS= read -r stat 2>/dev/null < /proc/"$pid"/stat || return 1
  rest=${stat#*) }
  read -r -a f <<< "$rest"
  pticks=$(( ${f[11]:-0} + ${f[12]:-0} ))
  for t in /proc/"$pid"/task/*; do
    tid=${t##*/}
    IFS= read -r stat 2>/dev/null < "$t/stat" || continue
    rest=${stat#*) }
    read -r -a f <<< "$rest"
    threads[$tid]=$(( ${f[11]:-0} + ${f[12]:-0} ))
    local c=${stat#*(}; comms[$tid]=${c%%)*}
  done
  read -r pread pwrite < <(awk '$1=="read_bytes:"{r=$2} $1=="write_bytes:"{w=$2} END{print r+0, w+0}' /proc/"$pid"/io 2>/dev/null)
  read -r pv pg peng pe pengines < <(proc_gpu "$pid")
}

# ---------- process resolution ----------
build_exclude() {
  local p=$$ s f
  EXCLUDE=" "
  while [[ -n $p && $p -gt 0 && -r /proc/$p/stat ]]; do
    EXCLUDE+="$p "
    IFS= read -r s 2>/dev/null < "/proc/$p/stat" || break
    s=${s#*) }
    read -r -a f <<< "$s"
    p=${f[1]:-0}
  done
}

plausible_match() {  # $1=pid $2=target: reject shells/wrappers, accept comm or argv[0] match
  local p=$1 t=$2 c cmd a0
  c=$(proc_name "$p" 2>/dev/null | tr 'A-Z' 'a-z')
  case $c in bash|sh|dash|zsh|fish|ksh|pgrep|grep|head|tail|script|timeout|sudo) return 1 ;; esac
  [[ $c == *"${t,,}"* ]] && return 0
  cmd=$(tr '\0' ' ' < /proc/"$p"/cmdline 2>/dev/null) || return 1
  a0=${cmd%% *}; a0=${a0##*/}
  [[ ${a0,,} == *"${t,,}"* ]] && return 0
  [[ $t == *" "* && ${cmd,,} == *"${t,,}"* ]] && return 0
  return 1
}

resolve_pid() {
  local t=$1 p best="" bestrss=-1 rss matches=() line
  if [[ $t =~ ^[0-9]+$ ]]; then echo "$t"; return 0; fi
  while IFS= read -r p; do matches+=("$p"); done < <(pgrep -x -- "$t" 2>/dev/null)
  if (( ${#matches[@]} == 0 )); then
    while IFS= read -r p; do
      [[ $EXCLUDE == *" $p "* ]] && continue
      plausible_match "$p" "$t" || continue
      matches+=("$p")
    done < <(pgrep -f -- "$t" 2>/dev/null)
  fi
  (( ${#matches[@]} > 0 )) || return 1
  for p in "${matches[@]}"; do
    [[ -r /proc/$p/statm ]] || continue
    read -r _ rss _ < /proc/"$p"/statm 2>/dev/null || continue
    if (( rss > bestrss )); then bestrss=$rss; best=$p; fi
  done
  [[ -n $best ]] || best=${matches[0]}
  PID_MATCHES=${#matches[@]}
  echo "$best"
}

proc_name() { local s; IFS= read -r s < /proc/"$1"/comm 2>/dev/null && echo "$s" || echo "?"; }
proc_rss_kb() { local sz r rest; read -r sz r rest < /proc/"$1"/statm 2>/dev/null && echo $(( r * PAGE_KB )) || echo 0; }
proc_swap_kb() { awk '/^VmSwap:/{print $2; exit}' /proc/"$1"/status 2>/dev/null; }

# ---------- rendering ----------
tty_ok=0; [[ -t 1 ]] && tty_ok=1
TERM_COLS=80; TERM_LINES=24; ROWS_CPU=5; ROWS_GPU=5
update_layout() {
  if (( tty_ok )); then
    TERM_COLS=$(tput cols 2>/dev/null || echo 80)
    TERM_LINES=$(tput lines 2>/dev/null || echo 24)
  else
    TERM_COLS=10000; TERM_LINES=200
  fi
  [[ $TERM_COLS =~ ^[0-9]+$ ]] || TERM_COLS=80
  [[ $TERM_LINES =~ ^[0-9]+$ ]] || TERM_LINES=24
  (( TERM_COLS < 40 )) && TERM_COLS=40
  (( TERM_LINES < 12 )) && TERM_LINES=12
  local avail=$(( TERM_LINES - 18 ))
  (( avail < 2 )) && avail=2
  ROWS_CPU=$(( avail / 2 ))
  (( ROWS_CPU > 5 )) && ROWS_CPU=5
  ROWS_GPU=$ROWS_CPU
}
USE_COLOR=0
if [[ $COLOR_MODE == always ]]; then
  USE_COLOR=1
elif [[ $COLOR_MODE == auto && $tty_ok == 1 && -z ${NO_COLOR:-} ]]; then
  USE_COLOR=1
fi
if (( USE_COLOR )); then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_GREEN=$'\033[1;32m'; C_YELLOW=$'\033[1;33m'; C_RED=$'\033[1;31m'
  C_HOT=$'\033[1;97;41m'; C_CYAN=$'\033[1;36m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_HOT=""; C_CYAN=""
fi
cleanup() {
  if (( tty_ok )); then
    tput cnorm 2>/dev/null || true
    tput rmcup 2>/dev/null || true
  fi
  exit 0
}
trap cleanup INT TERM
if (( tty_ok )); then
  tput civis 2>/dev/null || true
  tput smcup 2>/dev/null || true
fi

# severity color: green < 50, yellow < 75, red < 90, reverse-red >= 90
sev_color() {
  local n=${1%%.*}; n=${n:-0}; (( n < 0 )) && n=0
  if (( n >= 90 )); then printf '%s' "$C_HOT"
  elif (( n >= 75 )); then printf '%s' "$C_RED"
  elif (( n >= 50 )); then printf '%s' "$C_YELLOW"
  else printf '%s' "$C_GREEN"; fi
}
hcp() { printf '%s%s%s' "$(sev_color "$1")" "$1" "$C_RESET"; }   # highlighted percent
temp_c() {  # $1 = integer degrees (may be empty) -> colored "<n>C"
  local t=${1:-}
  [[ -n $t ]] || { printf '%s' '--'; return; }
  if (( t >= 80 )); then printf '%s%sC%s' "$C_HOT" "$t" "$C_RESET"
  elif (( t >= 65 )); then printf '%s%sC%s' "$C_RED" "$t" "$C_RESET"
  elif (( t >= 55 )); then printf '%s%sC%s' "$C_YELLOW" "$t" "$C_RESET"
  else printf '%s%sC%s' "$C_GREEN" "$t" "$C_RESET"; fi
}
hbar() {  # $1 percent, $2 width
  local p=${1%%.*} w=${2:-12} f i b=""
  (( p < 0 )) && p=0; (( p > 100 )) && p=100
  f=$(( p * w / 100 ))
  for (( i = 0; i < w; i++ )); do (( i < f )) && b+='#' || b+='.'; done
  printf '%s%s%s' "$(sev_color "$p")" "$b" "$C_RESET"
}
FRAME=""
add() { local ln; printf -v ln "$@"; FRAME+="$ln"$'\n'; }

clip_line() {  # $1 = line with ANSI codes, $2 = max visible chars
  local s=$1 max=$2 out="" i=0 n=0 len=${#1} c seq
  while (( i < len )); do
    c=${s:i:1}
    if [[ $c == $'\033' ]]; then
      seq=$c; (( i++ ))
      while (( i < len )); do
        c=${s:i:1}; seq+=$c; (( i++ ))
        [[ $c == [a-zA-Z] ]] && break
      done
      out+=$seq
    else
      (( n >= max )) && break
      out+=$c; (( n++ )); (( i++ ))
    fi
  done
  printf '%s%s' "$out" "$C_RESET"
}

emit_frame() {  # single write, line-by-line truncation, no stale fragments
  local out="" line
  while IFS= read -r line; do
    out+="$(clip_line "$line" $(( TERM_COLS - 1 )))"$'\033[K\n'
  done <<< "$FRAME"
  printf '\033[?2026h\033[H%s\033[J\033[?2026l' "$out"
}

render_header() {
  local up days h m l1 l2 l3 clock
  read -r up _ < /proc/uptime
  read -r l1 l2 l3 _ < /proc/loadavg
  up=${up%.*}
  days=$(( up / 86400 )); h=$(( up % 86400 / 3600 )); m=$(( up % 3600 / 60 ))
  printf -v clock '%(%H:%M:%S)T' -1
  add '%ssysmon%s %s  %sup %dd%dh%dm%s  load %s %s %s' \
    "$C_CYAN" "$C_RESET" "$clock" "$C_DIM" "$days" "$h" "$m" "$C_RESET" "$l1" "$l2" "$l3"
}

render_system() {
  local i used avail stotal sfree
  local dt=$(( CUR_CPU_TOTAL - PRE_CPU_TOTAL )) di=$(( CUR_CPU_IDLE - PRE_CPU_IDLE )) diw=$(( CUR_CPU_IOWAIT - PRE_CPU_IOWAIT ))
  local e=$(( ELAPSED_NS * CLK_TCK / 1000000000 )); (( e > 0 )) || e=1
  local busy=$(( dt - di - diw )) ncores=${#CUR_CORES[@]}
  local busy_pct idle_pct iow_pct barc=""
  busy_pct=$(pct10 "$busy" "$dt"); idle_pct=$(pct10 "$di" "$dt"); iow_pct=$(pct10 "$diw" "$dt")
  (( BARS )) && barc="$(hbar "$busy_pct" 12) "
  add 'CPU   %s%s%% (%s/%s)   idle %s%%  iowait %s%%   PSI %s%%/%s%%' \
    "$barc" "$(hcp "$busy_pct")" "$(cores2 "$busy" "$e")" "$ncores" "$idle_pct" "$iow_pct" \
    "$(psi10 cpu some)" "$(psi10 cpu full)"
  local percore=""
  for i in "${!CUR_CORES[@]}"; do
    read -r t idle _ <<< "${CUR_CORES[$i]}"
    read -r pt piddle _ <<< "${PRE_CORES[$i]}"
    percore+="$(hcp "$(pct10 $(( (t-pt) - (idle-piddle) )) "$e")") "
  done
  add '      cores %s' "$percore"
  read_mem
  used=$MEM_TOTAL; avail=$MEM_AVAIL; stotal=$SWAP_TOTAL; sfree=$SWAP_FREE
  local mem_pct=$(( used ? 100 * (used - avail) / used : 0 ))
  local swap_used swap_pct
  swap_used=$(( stotal - sfree ))
  swap_pct=$(( stotal ? 100 * swap_used / stotal : 0 ))
  local barm=""; (( BARS )) && barm="$(hbar "$mem_pct" 12) "
  add 'MEM   %s%s%%   %s / %s used   avail %s   swap %s / %s (%s%%)' \
    "$barm" "$(hcp "$mem_pct")" "$(fmt_kib_b $(( used - avail )))" "$(fmt_kib_b "$used")" \
    "$(fmt_kib_b "$avail")" "$(fmt_kib_b "$swap_used")" "$(fmt_kib_b "$stotal")" "$swap_pct"
  local vu vt gu gt
  read -r vu vt gu gt < <(gpu_sysfs)
  local vram_pct=$(( vt ? 100 * vu / vt : 0 )) gtt_pct=$(( gt ? 100 * gu / gt : 0 ))
  local barg=""; (( BARS )) && barg="$(hbar "$vram_pct" 12) "
  local gb="" gbusy
  gbusy=$(gpu_busy); [[ -n $gbusy ]] && gb="   busy $(hcp "$gbusy")%"
  add 'GPU   %sVRAM %s%%   %s / %s   GTT %s (%s%%)   temp %s%s' \
    "$barg" "$(hcp "$vram_pct")" "$(fmt_b "$vu")" "$(fmt_b "$vt")" "$(fmt_b "$gu")" "$gtt_pct" \
    "$(temp_c "$(read_temp "$HWM_GPU")")" "$gb"
  if (( GPU_TOP )) && (( ${#CUR_GPU_PIDS[@]} > 0 )); then
    local -A engsum=()
    local epid ename ens
    for epid in "${CUR_GPU_PIDS[@]}"; do
      while read -r ename ens; do
        engsum[$ename]=$(( ${engsum[$ename]:-0} + ens ))
      done < <(engine_deltas "${PRE_GPU_ENGINES[$epid]:-}" "${CUR_GPU_ENGINES[$epid]:-}")
    done
    if (( ${#engsum[@]} > 0 )); then
      local eline=""
      while read -r ename ens; do
        eline+="$ename $(hcp "$(pct10 "$ens" "$ELAPSED_NS")")%   "
      done < <(for ename in "${!engsum[@]}"; do echo "$ename ${engsum[$ename]}"; done | sort -k2,2rn | head -4)
      add 'ENGINE  %s' "$eline"
    fi
  fi
  add 'DISK  %s   read %s/s   write %s/s' "$ROOT_DISK" \
    "$(fmt_b "$(rate_b $(( CUR_DISK_R - PRE_DISK_R )) "$ELAPSED_NS" 512)")" \
    "$(fmt_b "$(rate_b $(( CUR_DISK_W - PRE_DISK_W )) "$ELAPSED_NS" 512)")"
  add 'TEMP  CPU %s   GPU %s   NVMe %s' "$(temp_c "$(read_temp "$HWM_CPU")")" "$(temp_c "$(read_temp "$HWM_GPU")")" "$(temp_c "$(read_temp "$HWM_NVME")")"
  add ''
  add '%sTOP CPU%s  (last %ss)' "$C_BOLD" "$C_RESET" "$INTERVAL"
  add '%s  %-8s %8s %10s  %s%s' "$C_DIM" PID CPU% RSS COMMAND "$C_RESET"
  local pid p10 pv ppad
  while read -r p10 pid; do
    [[ -n $pid ]] || continue
    pv=$(tenths "$p10"); printf -v ppad '%8s' "$pv"
    add '  %-8s %s %10s  %s' "$pid" "$(hcp "$ppad")" \
      "$(fmt_kib_b "$(proc_rss_kb "$pid")")" "$(proc_name "$pid")"
  done < <(
    for pid in "${!CUR_PROC_TICKS[@]}"; do
      [[ -n ${PRE_PROC_TICKS[$pid]+x} ]] || continue
      d=$(( CUR_PROC_TICKS[$pid] - PRE_PROC_TICKS[$pid] ))
      (( d > 0 )) && echo "$(awk -v d="$d" -v e="$e" 'BEGIN{printf "%d", d*1000/e}') $pid"
    done | sort -rn | head -"$ROWS_CPU"
  )
  if (( GPU_TOP )) && (( ${#CUR_GPU_PIDS[@]} > 0 )); then
    add ''
    local engine_total=0
    for pid in "${CUR_GPU_PIDS[@]}"; do
      [[ -n ${PRE_GPU_ENG[$pid]+x} ]] || continue
      d=$(( CUR_GPU_ENG[$pid] - PRE_GPU_ENG[$pid] ))
      (( d > 0 )) && engine_total=$(( engine_total + d ))
    done
    local use_engine=0; (( engine_total > 0 )) && use_engine=1
    if (( use_engine )); then
      add '%sTOP GPU%s  (engine busy, last %ss)' "$C_BOLD" "$C_RESET" "$INTERVAL"
      add '%s  %-8s %8s %10s  %s%s' "$C_DIM" PID GPU% VRAM COMMAND "$C_RESET"
    else
      add '%sTOP GPU%s  (by VRAM; no engine counters)' "$C_BOLD" "$C_RESET"
      add '%s  %-8s %10s  %s%s' "$C_DIM" PID VRAM COMMAND "$C_RESET"
    fi
    local gkey gv
    while read -r gkey gv pid; do
      [[ -n $pid ]] || continue
      if (( use_engine )); then
        local gpct gpad
        gpct=$(pct10 "$gkey" "$ELAPSED_NS")
        printf -v gpad '%8s' "$gpct"
        add '  %-8s %s %10s  %s' "$pid" "$(hcp "$gpad")" "$(fmt_kib_b "${CUR_GPU_VRAM[$pid]:-0}")" "$(proc_name "$pid")"
      else
        add '  %-8s %10s  %s' "$pid" "$(fmt_kib_b "${CUR_GPU_VRAM[$pid]:-0}")" "$(proc_name "$pid")"
      fi
    done < <(
      for pid in "${CUR_GPU_PIDS[@]}"; do
        if (( use_engine )); then
          d=0
          [[ -n ${PRE_GPU_ENG[$pid]+x} ]] && d=$(( CUR_GPU_ENG[$pid] - PRE_GPU_ENG[$pid] ))
          (( d < 0 )) && d=0
          echo "$d ${CUR_GPU_VRAM[$pid]:-0} $pid"
        else
          echo "${CUR_GPU_VRAM[$pid]:-0} 0 $pid"
        fi
      done | sort -k1,1rn -k2,2rn | head -"$ROWS_GPU"
    )
  fi
}

gpu_sysfs() {
  if [[ -n $GPU_DEV ]]; then
    echo "$(<"$GPU_DEV/mem_info_vram_used") $(<"$GPU_DEV/mem_info_vram_total") $(<"$GPU_DEV/mem_info_gtt_used") $(<"$GPU_DEV/mem_info_gtt_total")"
  elif (( NVIDIA )); then
    local line mu mt
    line=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [[ -n $line ]]; then
      IFS=', ' read -r mu mt <<< "$line"
      echo "$(( mu * 1048576 )) $(( mt * 1048576 )) 0 0"
    else
      echo "0 0 0 0"
    fi
  else
    echo "0 0 0 0"
  fi
}

gpu_busy() {  # integer GPU utilisation, or nothing when unsupported
  local v=""
  if [[ -n $GPU_DEV && -r $GPU_DEV/gpu_busy_percent ]]; then
    read -r v 2>/dev/null < "$GPU_DEV/gpu_busy_percent" || v=""
    [[ $v =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return; }
  fi
  if (( NVIDIA )); then
    v=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
    [[ $v =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return; }
  fi
}

render_proc() {
  local pid=$1 e dt
  e=$(( ELAPSED_NS * CLK_TCK / 1000000000 )); (( e > 0 )) || e=1
  dt=$(( CUR_PTICKS - PRE_PTICKS ))
  local ncores=${#CUR_CORES[@]} cpu_pct barp=""
  cpu_pct=$(pct10 "$dt" "$e")
  (( BARS )) && barp="$(hbar "$(( dt * 100 / e ))" 12) "
  add 'PROC  %s%s%s (pid %s)   RSS %s   swap %s   threads %s' \
    "$C_BOLD" "$(proc_name "$pid")" "$C_RESET" "$pid" \
    "$(fmt_kib_b "$(proc_rss_kb "$pid")")" "$(fmt_kib_b "$(proc_swap_kb "$pid")")" "${#CUR_THREAD_TICKS[@]}"
  add 'CPU   %s%s%% (%s cores of %s)' "$barp" "$(hcp "$cpu_pct")" "$(cores2 "$dt" "$e")" "$ncores"
  add '%sTHREADS%s  (top 5 by CPU; 100%% = one core)' "$C_BOLD" "$C_RESET"
  local tid p10 pv ppad trows=0
  while read -r p10 tid; do
    [[ -n $tid ]] || continue
    trows=$(( trows + 1 ))
    pv=$(tenths "$p10"); printf -v ppad '%7s' "$pv"
    add '  %s%%  %-8s %s' "$(hcp "$ppad")" "$tid" "${CUR_THREAD_COMM[$tid]:-?}"
  done < <(
    for tid in "${!CUR_THREAD_TICKS[@]}"; do
      [[ -n ${PRE_THREAD_TICKS[$tid]+x} ]] || continue
      d=$(( CUR_THREAD_TICKS[$tid] - PRE_THREAD_TICKS[$tid] ))
      (( d > 0 )) && echo "$(awk -v d="$d" -v e="$e" 'BEGIN{printf "%d", d*1000/e}') $tid"
    done | sort -rn | head -"$ROWS_CPU"
  )
  (( trows > 0 )) || add '  %s(no thread activity in this interval)%s' "$C_DIM" "$C_RESET"
  local vu vt gu gt
  read -r vu vt gu gt < <(gpu_sysfs)
  if (( CUR_PV > 0 )); then
    local eng_pct pvram_pct eline="" ename ens
    eng_pct=$(pct10 $(( CUR_ENGINE - PRE_ENGINE )) "$ELAPSED_NS")
    pvram_pct=$(( vt ? 100 * (CUR_PV * 1024) / vt : 0 ))
    while read -r ename ens; do
      eline+="$ename $(hcp "$(pct10 "$ens" "$ELAPSED_NS")")%   "
    done < <(engine_deltas "$PRE_PENGINES" "$CUR_PENGINES" | sort -k2,2rn | head -4)
    [[ -n $eline ]] || eline="idle   "
    add 'GPU   engines %s total %s%%' "$eline" "$(hcp "$eng_pct")"
    add 'GPU   VRAM %s/%s (%s%%)   GTT %s   evicted %s' \
      "$(fmt_kib_b "$CUR_PV")" "$(fmt_b "$vt")" "$(hcp "$pvram_pct")" \
      "$(fmt_kib_b "$CUR_PGT")" "$(fmt_kib_b "$CUR_PEV")"
  else
    add 'GPU   no DRM client found   system VRAM %s / %s   GTT %s' "$(fmt_b "$vu")" "$(fmt_b "$vt")" "$(fmt_b "$gu")"
  fi
  add 'DISK  read %s/s   write %s/s' \
    "$(fmt_b "$(rate_b $(( CUR_PREAD - PRE_PREAD )) "$ELAPSED_NS")")" \
    "$(fmt_b "$(rate_b $(( CUR_PWRITE - PRE_PWRITE )) "$ELAPSED_NS")")"
  local sbusy=$(( (CUR_CPU_TOTAL-CUR_CPU_IDLE) - (PRE_CPU_TOTAL-PRE_CPU_IDLE) )) sdt=$(( CUR_CPU_TOTAL - PRE_CPU_TOTAL ))
  local sb_pct
  sb_pct=$(pct10 "$sbusy" "$sdt")
  read_mem
  add 'SYS   CPU %s%% (%s/%s)   RAM avail %s   swap %s   TEMP CPU %s GPU %s' \
    "$(hcp "$sb_pct")" "$(cores2 "$sbusy" "$e")" "$ncores" \
    "$(fmt_kib_b "$MEM_AVAIL")" "$(fmt_kib_b $(( SWAP_TOTAL - SWAP_FREE )))" \
    "$(temp_c "$(read_temp "$HWM_CPU")")" "$(temp_c "$(read_temp "$HWM_GPU")")"
}

render_footer() {
  add ''
  add '%sVRAM near 100%% + GTT/evicted rising = texture thrash;  gfx near 100%% = GPU-bound;%s' "$C_DIM" "$C_RESET"
  add '%sone thread near 100%% while cores idle = single-core bound.  Ctrl-C quits.%s' "$C_DIM" "$C_RESET"
}

# ---------- main loop ----------
PID_MATCHES=0
build_exclude
if [[ -n $TARGET ]]; then
  pid=$(resolve_pid "$TARGET") || { echo "no process matches '$TARGET'" >&2; exit 1; }
  echo "target '$TARGET' -> pid $pid ($(proc_name "$pid"))" >&2
  (( PID_MATCHES > 1 )) && echo "note: $PID_MATCHES processes matched, picked the largest RSS" >&2
  snapshot_proc PRE "$pid"
else
  snapshot_system PRE
fi

iter=0
ELAPSED_NS=$(( INTERVAL * 1000000000 ))
PRE_NS=$(date +%s%N)
while :; do
  sleep "$INTERVAL"
  if [[ -n $TARGET ]]; then
    if [[ ! $TARGET =~ ^[0-9]+$ ]]; then
      newpid=$(resolve_pid "$TARGET") || { echo "process exited"; cleanup; }
      pid=$newpid
    fi
    [[ -d /proc/$pid ]] || { echo "pid $pid exited"; cleanup; }
    snapshot_proc CUR "$pid" || { echo "pid $pid exited"; cleanup; }
  else
    snapshot_system CUR
  fi
  CUR_NS=$(date +%s%N)
  ELAPSED_NS=$(( CUR_NS - PRE_NS )); (( ELAPSED_NS > 0 )) || ELAPSED_NS=1000000000
  FRAME=""
  update_layout
  render_header
  if [[ -n $TARGET ]]; then render_proc "$pid"; else render_system; fi
  render_footer
  if (( tty_ok )); then
    # one write per frame, clipped to the window, erase-to-EOL per line
    emit_frame
  else
    printf '%s' "$FRAME"
    printf '%s\n' '----------------------------------------'
  fi
  (( ++iter ))
  (( COUNT > 0 && iter >= COUNT )) && break
  # rotate PRE <- CUR
  if [[ -n $TARGET ]]; then
    PRE_CPU_TOTAL=$CUR_CPU_TOTAL; PRE_CPU_IDLE=$CUR_CPU_IDLE; PRE_CPU_IOWAIT=$CUR_CPU_IOWAIT
    PRE_PTICKS=$CUR_PTICKS; PRE_PREAD=$CUR_PREAD; PRE_PWRITE=$CUR_PWRITE
    PRE_ENGINE=$CUR_ENGINE; PRE_PV=$CUR_PV; PRE_PGT=$CUR_PGT; PRE_PEV=$CUR_PEV
    PRE_PENGINES=$CUR_PENGINES
    PRE_DISK_R=$CUR_DISK_R; PRE_DISK_W=$CUR_DISK_W
    PRE_THREAD_TICKS=(); for k in "${!CUR_THREAD_TICKS[@]}"; do PRE_THREAD_TICKS[$k]=${CUR_THREAD_TICKS[$k]}; done
    PRE_THREAD_COMM=(); for k in "${!CUR_THREAD_COMM[@]}"; do PRE_THREAD_COMM[$k]=${CUR_THREAD_COMM[$k]}; done
  else
    PRE_CPU_TOTAL=$CUR_CPU_TOTAL; PRE_CPU_IDLE=$CUR_CPU_IDLE; PRE_CPU_IOWAIT=$CUR_CPU_IOWAIT
    PRE_CORES=("${CUR_CORES[@]}")
    PRE_DISK_R=$CUR_DISK_R; PRE_DISK_W=$CUR_DISK_W
    PRE_PROC_TICKS=(); for k in "${!CUR_PROC_TICKS[@]}"; do PRE_PROC_TICKS[$k]=${CUR_PROC_TICKS[$k]}; done
    PRE_GPU_PIDS=("${CUR_GPU_PIDS[@]}")
    PRE_GPU_VRAM=(); for k in "${!CUR_GPU_VRAM[@]}"; do PRE_GPU_VRAM[$k]=${CUR_GPU_VRAM[$k]}; done
    PRE_GPU_GTT=(); for k in "${!CUR_GPU_GTT[@]}"; do PRE_GPU_GTT[$k]=${CUR_GPU_GTT[$k]}; done
    PRE_GPU_ENG=(); for k in "${!CUR_GPU_ENG[@]}"; do PRE_GPU_ENG[$k]=${CUR_GPU_ENG[$k]}; done
    PRE_GPU_EV=(); for k in "${!CUR_GPU_EV[@]}"; do PRE_GPU_EV[$k]=${CUR_GPU_EV[$k]}; done
    PRE_GPU_ENGINES=(); for k in "${!CUR_GPU_ENGINES[@]}"; do PRE_GPU_ENGINES[$k]=${CUR_GPU_ENGINES[$k]}; done
  fi
  PRE_NS=$CUR_NS
done
cleanup
