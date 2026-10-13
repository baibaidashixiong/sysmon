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
VERSION="0.5.0"

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
MEM_DETAIL=0
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
  -m           expanded memory breakdown (free/cached/slab/anon/commit/swap IO)
  -v           print version
  -h           show this help

Examples:
  ~/sysmon.sh
  ~/sysmon.sh -i 2 DyingLightGame
  ~/sysmon.sh 14594
EOF
}

while getopts ":i:n:pcvGmh" opt; do
  case $opt in
    i) INTERVAL=$OPTARG ;;
    n) COUNT=$OPTARG ;;
    p) COLOR_MODE=never; BARS=0 ;;
    c) COLOR_MODE=always ;;
    G) GPU_TOP=0 ;;
    m) MEM_DETAIL=1 ;;
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
GPU_MODEL=""
GPU_VRAM_OK=0
_best=0
for c in /sys/class/drm/card*/device; do
  [[ -r $c/mem_info_vram_total ]] || continue
  _t=0
  read -r _t 2>/dev/null < "$c/mem_info_vram_total"
  [[ $_t =~ ^[0-9]+$ ]] || _t=0
  if (( _t > _best )); then _best=$_t; GPU_DEV=$c; fi
done
unset _best _t
if [[ -n $GPU_DEV ]]; then
  read -r _t 2>/dev/null < "$GPU_DEV/mem_info_vram_total" || _t=0
  (( ${_t:-0} > 0 )) && GPU_VRAM_OK=1
  unset _t
fi
GPU_DRIVER=""
[[ -n $GPU_DEV ]] && GPU_DRIVER=$(basename "$(readlink -f "$GPU_DEV/driver" 2>/dev/null)" 2>/dev/null)
NVIDIA=0
command -v nvidia-smi >/dev/null 2>&1 && NVIDIA=1
[[ -z $GPU_DRIVER && $NVIDIA == 1 ]] && GPU_DRIVER=nvidia
if command -v lspci >/dev/null 2>&1; then
  GPU_MODEL=$(lspci 2>/dev/null | awk '/VGA compatible controller|3D controller|Display controller/ {sub(/^.*: */, ""); print; exit}')
  [[ $GPU_MODEL == *'['*']'* ]] && GPU_MODEL=$(printf '%s' "$GPU_MODEL" | sed 's/.*\[\([^]]*\)\].*/\1/')
fi

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
DEFAULT_IFACE=$(awk '$2=="00000000" {print $1; exit}' /proc/net/route 2>/dev/null)

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
  MEM_FREE=0; MEM_BUFFERS=0; MEM_CACHED=0; MEM_SHMEM=0
  MEM_SLAB=0; MEM_SRECLAIM=0; MEM_PGTAB=0
  MEM_ANON=0; MEM_MAPPED=0; MEM_ACTIVE=0; MEM_INACTIVE=0
  MEM_DIRTY=0; MEM_WRITEBACK=0; MEM_COMMIT=0; MEM_COMMITLIM=0; MEM_SWAPCACHED=0
  local k v
  while read -r k v _; do
    case $k in
      MemTotal:) MEM_TOTAL=$v ;; MemAvailable:) MEM_AVAIL=$v ;;
      SwapTotal:) SWAP_TOTAL=$v ;; SwapFree:) SWAP_FREE=$v ;;
      MemFree:) MEM_FREE=$v ;; Buffers:) MEM_BUFFERS=$v ;; Cached:) MEM_CACHED=$v ;;
      Shmem:) MEM_SHMEM=$v ;; Slab:) MEM_SLAB=$v ;; SReclaimable:) MEM_SRECLAIM=$v ;;
      PageTables:) MEM_PGTAB=$v ;; AnonPages:) MEM_ANON=$v ;; Mapped:) MEM_MAPPED=$v ;;
      Active:) MEM_ACTIVE=$v ;; Inactive:) MEM_INACTIVE=$v ;;
      Dirty:) MEM_DIRTY=$v ;; Writeback:) MEM_WRITEBACK=$v ;;
      Committed_AS:) MEM_COMMIT=$v ;; CommitLimit:) MEM_COMMITLIM=$v ;;
      SwapCached:) MEM_SWAPCACHED=$v ;;
    esac
  done < /proc/meminfo
}

read_vmstat_swap() {  # sets PSWPIN/PSWPOUT (pages since boot)
  PSWPIN=0; PSWPOUT=0
  local k v
  while read -r k v _; do
    case $k in pswpin:) PSWPIN=$v ;; pswpout:) PSWPOUT=$v ;; esac
  done < /proc/vmstat
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
declare -A ENG_DELTA ENG_TOTAL
declare -A LABEL_CACHE
declare -a GPU_PATHS=()
GPU_PATH_AGE=999
declare -A PRE_NET_RX CUR_NET_RX PRE_NET_TX CUR_NET_TX
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
  snapshot_net "$tag"
  procs_snapshot "$tag"
  gpu_scan_all "$tag"
}

procs_snapshot() {  # $1=tag; one pass over every /proc/<pid>/stat
  local -n ticks="${1}_PROC_TICKS"
  ticks=()
  local pid t
  while read -r pid t; do
    [[ -n $pid ]] && ticks[$pid]=$t
  done < <(grep -H '^' /proc/[0-9]*/stat 2>/dev/null | awk '
    {
      i=index($0,":"); path=substr($0,1,i-1); rest=substr($0,i+1)
      j=0
      for (k=length(rest); k>0; k--) if (substr(rest,k,1)==")") { j=k; break }
      if (!j) next
      split(substr(rest,j+2), fs, /[ \t]+/)
      split(path, pa, "/")
      printf "%s %d\n", pa[3], fs[12]+fs[13]
    }')
}

gpu_scan_all() {  # $1=tag; one grep+awk pass over every DRM client on the box
  local tag=$1
  local -n gpids="${tag}_GPU_PIDS" gvram="${tag}_GPU_VRAM" ggtt="${tag}_GPU_GTT"
  local -n geng="${tag}_GPU_ENG" gev="${tag}_GPU_EV" gengines="${tag}_GPU_ENGINES"
  gpids=(); gvram=(); ggtt=(); geng=(); gev=(); gengines=()
  (( GPU_TOP )) || return 0
  # full directory walk only every few frames; otherwise reuse the client list
  if (( GPU_PATH_AGE >= 5 )) || (( ${#GPU_PATHS[@]} == 0 )); then
    mapfile -t GPU_PATHS < <(grep -l -m1 '^drm-client-id:' /proc/[0-9]*/fdinfo/* 2>/dev/null)
    GPU_PATH_AGE=0
  else
    GPU_PATH_AGE=$(( GPU_PATH_AGE + 1 ))
  fi
  (( ${#GPU_PATHS[@]} > 0 )) || return 0
  local pid v g e ev engs
  while IFS='|' read -r pid v g e ev engs; do
    [[ -n $pid ]] || continue
    gpids+=("$pid")
    gvram[$pid]=$v; ggtt[$pid]=$g; geng[$pid]=$e; gev[$pid]=$ev; gengines[$pid]=$engs
  done < <(
    grep -H -E '^(drm-client-id|drm-pdev|drm-memory-vram|drm-memory-gtt|drm-engine-|amd-evicted-vram)' \
      "${GPU_PATHS[@]}" 2>/dev/null | awk '
      {
        i=index($0,":"); path=substr($0,1,i-1); line=substr($0,i+1)
        if (path != cur) { cur=path; cid=""; pdev=""; split(path,pa,"/"); pid=pa[3] }
        split(line,f,/[ \t]+/); key=f[1]
        pids[pid]=1
        if (key=="drm-client-id:") cid=f[2]
        else if (key=="drm-pdev:") { pdev=f[2]; gsub(/[:.]/,"_",pdev) }
        else if (key=="drm-memory-vram:") { k=pid SUBSEP pdev SUBSEP cid; if(!(k in vr)) vr[k]=f[2]+0 }
        else if (key=="drm-memory-gtt:")  { k=pid SUBSEP pdev SUBSEP cid; if(!(k in gt)) gt[k]=f[2]+0 }
        else if (key=="amd-evicted-vram:"){ k=pid SUBSEP pdev SUBSEP cid; if(!(k in ev)) ev[k]=f[2]+0 }
        else if (key ~ /^drm-engine-/) {
          name=key; sub(/^drm-engine-/,"",name); sub(/:$/,"",name)
          k=pid SUBSEP pdev SUBSEP cid SUBSEP name
          if(!(k in en)) en[k]=f[2]+0
        }
      }
      END{
        for(k in vr){split(k,a,SUBSEP); pv[a[1]]+=vr[k]}
        for(k in gt){split(k,a,SUBSEP); pg[a[1]]+=gt[k]}
        for(k in ev){split(k,a,SUBSEP); pe[a[1]]+=ev[k]}
        for(k in en){split(k,a,SUBSEP); pt[a[1]]+=en[k]; es[a[1]]=es[a[1]] a[2]"/"a[3]"/"a[4]"="en[k]" "}
        for(q in pids) printf "%s|%d|%d|%d|%d|%s\n", q, pv[q]+0, pg[q]+0, pt[q]+0, pe[q]+0, es[q]
      }
    '
  )
}

snapshot_net() {  # $1=tag; collects per-interface rx/tx byte counters
  local -n nrx="${1}_NET_RX" ntx="${1}_NET_TX"
  nrx=(); ntx=()
  local iface r t
  while read -r iface r t; do
    [[ $iface == lo ]] && continue
    nrx[$iface]=$r; ntx[$iface]=$t
  done < <(awk 'NR>2 {gsub(/^[ \t]+/, ""); split($0, p, /[ \t]+/); sub(/:$/, "", p[1]); print p[1], p[2], p[10]}' /proc/net/dev 2>/dev/null)
}

proc_sockets() {  # $1=pid -> "total established listen udp"
  awk '
    FNR==NR { gsub(/[^0-9]/, "", $0); if ($0 != "") { want[$0]=1; total++ } next }
    FILENAME ~ /udp/ { if ($10 in want) u++; next }
    FILENAME ~ /tcp/ { if ($10 in want) { if ($4=="01") e++; else if ($4=="0A") l++ } }
    END { printf "%d %d %d %d\n", total+0, e+0, l+0, u+0 }
  ' <(find /proc/"$1"/fd -maxdepth 1 -type l -lname 'socket:*' -printf '%l\n' 2>/dev/null) \
    /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6 2>/dev/null
}

proc_gpu() {  # $1=pid -> "vram_kib gtt_kib engine_ns evicted_kib"
  # fdinfo files can vanish while a busy process opens/closes fds; gawk aborts
  # on a missing input file, so feed it through cat (which skips failures).
  find /proc/"$1"/fdinfo -maxdepth 1 -type f -exec cat {} + 2>/dev/null | awk '
    /^drm-client-id:/ {cid=$2}
    /^drm-pdev:/ {pdev=$2; gsub(/[:.]/, "_", pdev)}
    /^drm-memory-vram:/ {if(cid!="" && !(cid in v)) v[cid]=$2+0}
    /^drm-memory-gtt:/  {if(cid!="" && !(cid in g)) g[cid]=$2+0}
    /^drm-engine-/ {
      if (cid != "" && pdev != "") {
        name=$1; sub(/^drm-engine-/, "", name); sub(/:$/, "", name)
        key=pdev SUBSEP cid SUBSEP name
        if (!(key in em)) em[key]=$2+0
      }
    }
    /^amd-evicted-vram:/{if(cid!="" && !(cid in ev)) ev[cid]=$2+0}
    END{
      tv=tg=te=tev=0
      for(c in v)tv+=v[c]; for(c in g)tg+=g[c]
      for(c in ev)tev+=ev[c]
      eng=""
      for(k in em){split(k,a,SUBSEP); te+=em[k]; eng=eng a[1] "/" a[2] "/" a[3] "=" em[k] " "}
      printf "%d %d %d %d %s\n", tv, tg, te, tev, eng
    }
  '
}

engine_deltas() {  # $1=prev $2=cur, entries "client/engine:ns"; only matching clients count
  local -A P=() C=() D=()
  local kv key name d
  for kv in $1; do P[${kv%%=*}]=${kv#*=}; done
  for kv in $2; do C[${kv%%=*}]=${kv#*=}; done
  for key in "${!C[@]}"; do
    [[ -n ${P[$key]+x} ]] || continue        # new client/engine: no baseline yet
    d=$(( C[$key] - P[$key] ))
    (( d > 0 )) || continue                  # counter reset or idle
    name=${key##*/}
    D[$name]=$(( ${D[$name]:-0} + d ))
  done
  for name in "${!D[@]}"; do printf '%s %d\n' "$name" "${D[$name]}"; done
}

engine_total_delta() {  # $1=prev $2=cur -> total ns over matching client/engine pairs
  local -A P=() C=()
  local kv key d total=0
  for kv in $1; do P[${kv%%=*}]=${kv#*=}; done
  for kv in $2; do C[${kv%%=*}]=${kv#*=}; done
  for key in "${!C[@]}"; do
    [[ -n ${P[$key]+x} ]] || continue
    d=$(( C[$key] - P[$key] ))
    (( d > 0 )) && total=$(( total + d ))
  done
  printf '%d' "$total"
}

engine_delta_v() {  # $1=prev $2=cur -> ENGDELTA "name ns ..." and ENGTOTAL ns
  local -A P=() C=() D=()
  local kv key name d
  for kv in $1; do P[${kv%%=*}]=${kv#*=}; done
  for kv in $2; do C[${kv%%=*}]=${kv#*=}; done
  ENGTOTAL=0; ENGDELTA=""
  for key in "${!C[@]}"; do
    [[ -n ${P[$key]+x} ]] || continue
    d=$(( C[$key] - P[$key] ))
    (( d > 0 )) || continue
    name=${key##*/}
    D[$name]=$(( ${D[$name]:-0} + d ))
    ENGTOTAL=$(( ENGTOTAL + d ))
  done
  for name in "${!D[@]}"; do ENGDELTA+="$name ${D[$name]} "; done
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

proc_name() { local s; IFS= read -r s 2>/dev/null < /proc/"$1"/comm && echo "$s" || echo "?"; }
proc_label_v() {  # sets LABEL: comm plus a meaningful app/exe label when renamed
  local pid=$1 c e label="" arg
  c=$(proc_name "$pid")
  local cached=${LABEL_CACHE[$pid]:-}
  if [[ -n $cached && ${cached%%$'\t'*} == "$c" ]]; then
    LABEL=${cached#*$'\t'}
    return
  fi
  e=$(readlink "/proc/$pid/exe" 2>/dev/null) || e=""
  e=${e##*/}
  if [[ -r /proc/$pid/cmdline ]]; then
    while IFS= read -r -d '' arg; do
      case ${arg,,} in
        *.exe) label=${arg##*[\\/]}; break ;;
      esac
    done < /proc/"$pid"/cmdline
  fi
  [[ -n $label ]] || label=$e
  if [[ -n $label && $label != "$c" ]]; then
    LABEL="$c [$label]"
  else
    LABEL=$c
  fi
  LABEL_CACHE[$pid]="$c"$'\t'"$LABEL"
}
proc_label() { proc_label_v "$1"; printf '%s' "$LABEL"; }
proc_rss_kb() { local sz r rest; read -r sz r rest < /proc/"$1"/statm 2>/dev/null && echo $(( r * PAGE_KB )) || echo 0; }
rss_kb_v() { local sz r rest; RSS_KB=0; read -r sz r rest < /proc/"$1"/statm 2>/dev/null && RSS_KB=$(( r * PAGE_KB )); }
proc_swap_kb() { awk '/^VmSwap:/{print $2; exit}' /proc/"$1"/status 2>/dev/null; }
proc_swap_kb_v() {
  local k v u; SWAP_KB=0
  while read -r k v u; do [[ $k == VmSwap: ]] && { SWAP_KB=${v:-0}; break; }; done < /proc/"$1"/status 2>/dev/null
}

read_smaps_v() {  # $1=pid -> SMAPS_RSS/PSS/ANON/SHARED/PRIVATE/SWAP (KiB)
  SMAPS_RSS=0; SMAPS_PSS=0; SMAPS_ANON=0; SMAPS_SHARED=0; SMAPS_PRIVATE=0; SMAPS_SWAP=0
  SMAPS_PSS_ANON=0; SMAPS_PSS_FILE=0; SMAPS_SWAP_PSS=0; SMAPS_LOCKED=0; SMAPS_HUGE=0
  local k v u
  while read -r k v u; do
    case $k in
      Rss:) SMAPS_RSS=${v:-0} ;;
      Pss:) SMAPS_PSS=${v:-0} ;;
      Anonymous:) SMAPS_ANON=${v:-0} ;;
      Shared_Clean:|Shared_Dirty:) SMAPS_SHARED=$(( SMAPS_SHARED + ${v:-0} )) ;;
      Private_Clean:|Private_Dirty:) SMAPS_PRIVATE=$(( SMAPS_PRIVATE + ${v:-0} )) ;;
      Swap:) SMAPS_SWAP=${v:-0} ;;
      Pss_Anon:) SMAPS_PSS_ANON=${v:-0} ;;
      Pss_File:) SMAPS_PSS_FILE=${v:-0} ;;
      SwapPss:) SMAPS_SWAP_PSS=${v:-0} ;;
      Locked:) SMAPS_LOCKED=${v:-0} ;;
      AnonHugePages:) SMAPS_HUGE=${v:-0} ;;
    esac
  done < /proc/"$1"/smaps_rollup 2>/dev/null
}

read_status_mem_v() {  # $1=pid -> STA_PEAK/VIRT/DATA/STK/EXE/LIB/PTE (KiB)
  STA_PEAK=0; STA_VIRT=0; STA_DATA=0; STA_STK=0; STA_EXE=0; STA_LIB=0; STA_PTE=0
  local k v u
  while read -r k v u; do
    case $k in
      VmPeak:) STA_PEAK=${v:-0} ;;
      VmSize:) STA_VIRT=${v:-0} ;;
      VmData:) STA_DATA=${v:-0} ;;
      VmStk:) STA_STK=${v:-0} ;;
      VmExe:) STA_EXE=${v:-0} ;;
      VmLib:) STA_LIB=${v:-0} ;;
      VmPTE:) STA_PTE=${v:-0} ;;
    esac
  done < /proc/"$1"/status 2>/dev/null
}

# ---------- rendering ----------
tty_ok=0; [[ -t 1 ]] && tty_ok=1
TERM_COLS=80; TERM_LINES=24; ROWS_CPU=5; ROWS_GPU=5; ROWS_MEM=5
LAYOUT_AGE=999
update_layout() {
  (( LAYOUT_AGE < 5 )) && { LAYOUT_AGE=$(( LAYOUT_AGE + 1 )); return; }
  LAYOUT_AGE=0
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
  local extra=0
  (( MEM_DETAIL )) && extra=3
  local avail=$(( TERM_LINES - 21 - extra ))
  (( avail < 3 )) && avail=3
  ROWS_CPU=$(( avail / 3 ))
  (( ROWS_CPU > 5 )) && ROWS_CPU=5
  (( ROWS_CPU < 1 )) && ROWS_CPU=1
  ROWS_GPU=$ROWS_CPU
  ROWS_MEM=$ROWS_CPU
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

# no-fork variants: write to globals instead of spawning a subshell per value
SEV=""; HCP=""; BAR=""; PCT10="0.0"; TENTHS="0.0"; CORES2="0.00"
FMTB="0.0B"; FMTM="0K"; RATE=0; TEMPC="--"; PSI="n/a"; TEMP=""
v_sev() {
  local n=${1%%.*}; n=${n:-0}; (( n < 0 )) && n=0
  if (( n >= 90 )); then SEV=$C_HOT
  elif (( n >= 75 )); then SEV=$C_RED
  elif (( n >= 50 )); then SEV=$C_YELLOW
  else SEV=$C_GREEN; fi
}
v_hcp() { v_sev "$1"; HCP="$SEV$1$C_RESET"; }
v_bar() {
  local p=${1%%.*} w=${2:-12} f i b=""
  (( p < 0 )) && p=0; (( p > 100 )) && p=100
  f=$(( p * w / 100 ))
  for (( i = 0; i < w; i++ )); do (( i < f )) && b+='#' || b+='.'; done
  v_sev "$p"; BAR="$SEV$b$C_RESET"
}
v_pct10() {
  local d=${1:-0} e=${2:-0} v
  if (( e <= 0 )); then PCT10="0.0"; return; fi
  (( d < 0 )) && d=0
  v=$(( d * 1000 / e )); PCT10="$(( v / 10 )).$(( v % 10 ))"
}
v_tenths() { local v=${1:-0}; (( v < 0 )) && v=0; TENTHS="$(( v / 10 )).$(( v % 10 ))"; }
v_cores2() {
  local d=${1:-0} e=${2:-0} v
  if (( e <= 0 )); then CORES2="0.00"; return; fi
  (( d < 0 )) && d=0
  v=$(( d * 100 / e )); CORES2="$(( v / 100 )).$(printf '%02d' $(( v % 100 )))"
}
v_fmt_b() {
  local b=${1:-0} s="" u=1 suf=B t
  (( b < 0 )) && { s="-"; b=$(( -b )); }
  if (( b >= 1073741824 )); then u=1073741824; suf=G
  elif (( b >= 1048576 )); then u=1048576; suf=M
  elif (( b >= 1024 )); then u=1024; suf=K
  fi
  t=$(( (b * 10 + u / 2) / u ))
  FMTB="$s$(( t / 10 )).$(( t % 10 ))$suf"
}
v_fmt_kib() { v_fmt_b $(( ${1:-0} * 1024 )); }
v_fmt_mem() {  # $1 bytes? no: KiB -> adaptive precision (15.5G / 8.62G / 512M)
  local kib=${1:-0} s="" t
  (( kib < 0 )) && { s="-"; kib=$(( -kib )); }
  if (( kib >= 10485760 )); then
    t=$(( (kib * 10 + 524288) / 1048576 )); FMTM="$s$(( t / 10 )).$(( t % 10 ))G"
  elif (( kib >= 1048576 )); then
    t=$(( (kib * 100 + 524288) / 1048576 )); FMTM="$s$(( t / 100 )).$(printf '%02d' $(( t % 100 )))G"
  elif (( kib >= 102400 )); then
    FMTM="$s$(( (kib + 512) / 1024 ))M"
  elif (( kib >= 1024 )); then
    t=$(( (kib * 10 + 512) / 1024 )); FMTM="$s$(( t / 10 )).$(( t % 10 ))M"
  else
    FMTM="$s${kib}K"
  fi
}
v_rate() {
  local d=${1:-0} ns=${2:-0} m=${3:-1} ms t
  if (( ns <= 0 )); then RATE=0; return; fi
  ms=$(( ns / 1000000 )); (( ms > 0 )) || ms=1
  t=$(( d * m * 1000 / ms )); (( t < 0 )) && t=0
  RATE=$t
}
v_temp() {
  local t=${1:-}
  if [[ -z $t ]]; then TEMPC="--"; return; fi
  if (( t >= 80 )); then SEV=$C_HOT
  elif (( t >= 65 )); then SEV=$C_RED
  elif (( t >= 55 )); then SEV=$C_YELLOW
  else SEV=$C_GREEN; fi
  TEMPC="$SEV${t}C$C_RESET"
}
read_temp_v() {
  local t; TEMP=""
  [[ -n ${1:-} && -r $1/temp1_input ]] || return 0
  read -r t 2>/dev/null < "$1/temp1_input"; TEMP=$(( ${t:-0} / 1000 ))
}
v_psi() {
  local f=$1 want=$2 line x
  PSI="n/a"
  while IFS= read -r line; do
    [[ $line == "$want "* ]] || continue
    for x in $line; do [[ $x == avg10=* ]] && { PSI=${x#avg10=}; return; }; done
  done < "/proc/pressure/$f" 2>/dev/null
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

clip_line_v() {  # sets CLIPPED: $1 = line with ANSI codes, $2 = max visible chars
  local s=$1 max=$2 out="" i=0 n=0 len=${#1} c seq
  local plain=${s//$'\033'\[*([0-9;?])[a-zA-Z]/}
  if (( ${#plain} <= max )); then CLIPPED=$s; return; fi
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
  CLIPPED="$out$C_RESET"
}
clip_line() { clip_line_v "$1" "$2"; printf '%s' "$CLIPPED"; }

emit_frame() {  # single write, line-by-line truncation, no stale fragments
  local out="" line n=0 max=$(( TERM_LINES - 1 ))
  while IFS= read -r line; do
    (( n >= max )) && break
    clip_line_v "$line" $(( TERM_COLS - 1 ))
    out+="$CLIPPED"$'\033[K\n'
    (( n++ ))
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
  local busy_pct idle_pct iow_pct barc="" hbusy cores2v p1 p2
  v_pct10 "$busy" "$dt"; busy_pct=$PCT10
  v_pct10 "$di" "$dt"; idle_pct=$PCT10
  v_pct10 "$diw" "$dt"; iow_pct=$PCT10
  if (( BARS )); then v_bar "$busy_pct" 12; barc="$BAR "; fi
  v_hcp "$busy_pct"; hbusy=$HCP
  v_cores2 "$busy" "$e"; cores2v=$CORES2
  v_psi cpu some; p1=$PSI
  v_psi cpu full; p2=$PSI
  add 'CPU   %s%s%% (%s/%s)   idle %s%%  iowait %s%%   PSI %s%%/%s%%' \
    "$barc" "$hbusy" "$cores2v" "$ncores" "$idle_pct" "$iow_pct" "$p1" "$p2"
  local percore=""
  for i in "${!CUR_CORES[@]}"; do
    read -r t idle _ <<< "${CUR_CORES[$i]}"
    read -r pt piddle _ <<< "${PRE_CORES[$i]}"
    v_pct10 $(( (t-pt) - (idle-piddle) )) "$e"; v_hcp "$PCT10"
    percore+="$HCP "
  done
  add '      cores %s' "$percore"
  read_mem
  used=$MEM_TOTAL; avail=$MEM_AVAIL; stotal=$SWAP_TOTAL; sfree=$SWAP_FREE
  local mem_pct=$(( used ? 100 * (used - avail) / used : 0 ))
  local swap_used swap_pct
  swap_used=$(( stotal - sfree ))
  swap_pct=$(( stotal ? 100 * swap_used / stotal : 0 ))
  local barm="" hm f1 f2 f3 f4 f5
  local mem_pct_x
  v_pct10 $(( used - avail )) "$used"; mem_pct_x=$PCT10
  if (( BARS )); then v_bar "$mem_pct" 12; barm="$BAR "; fi
  v_hcp "$mem_pct_x"; hm=$HCP
  v_fmt_mem $(( used - avail )); f1=$FMTM
  v_fmt_mem "$used"; f2=$FMTM
  v_fmt_mem "$avail"; f3=$FMTM
  v_fmt_mem "$swap_used"; f4=$FMTM
  v_fmt_mem "$stotal"; f5=$FMTM
  local md=${MEM_DELTA_KIB:-0} msign="+" mcolor=$C_DIM
  (( md < 0 )) && { msign="-"; md=$(( -md )); }
  v_rate $(( md * 1024 )) "$ELAPSED_NS"
  if (( RATE >= 10485760 )); then mcolor=$C_RED
  elif (( RATE >= 1048576 )); then mcolor=$C_YELLOW
  elif [[ $msign == "-" ]]; then mcolor=$C_GREEN; fi
  v_fmt_mem $(( RATE / 1024 ))
  add 'MEM   %s%s%%   %s / %s used   avail %s   swap %s / %s (%s%%)   %s%s%s' \
    "$barm" "$hm" "$f1" "$f2" "$f3" "$f4" "$f5" "$swap_pct" \
    "$mcolor" "$msign$FMTM/s" "$C_RESET"
  if (( MEM_DETAIL )); then
    local e1 e2 e3 e4 e5 e6 e7 commit_pct=0
    v_fmt_mem "$MEM_FREE"; e1=$FMTM
    v_fmt_mem "$MEM_BUFFERS"; e2=$FMTM
    v_fmt_mem "$MEM_CACHED"; e3=$FMTM
    v_fmt_mem "$MEM_SHMEM"; e4=$FMTM
    v_fmt_mem "$MEM_SLAB"; e5=$FMTM
    v_fmt_mem "$MEM_SRECLAIM"; e6=$FMTM
    v_fmt_mem "$MEM_PGTAB"; e7=$FMTM
    add 'MEM   free %s   buffers %s   cached %s   shmem %s   slab %s (reclaimable %s)   pagetables %s' \
      "$e1" "$e2" "$e3" "$e4" "$e5" "$e6" "$e7"
    v_fmt_mem "$MEM_ANON"; e1=$FMTM
    v_fmt_mem "$MEM_MAPPED"; e2=$FMTM
    v_fmt_mem "$MEM_ACTIVE"; e3=$FMTM
    v_fmt_mem "$MEM_INACTIVE"; e4=$FMTM
    v_fmt_mem "$MEM_DIRTY"; e5=$FMTM
    v_fmt_mem "$MEM_WRITEBACK"; e6=$FMTM
    add 'MEM   anon %s   mapped %s   active %s   inactive %s   dirty %s   writeback %s' \
      "$e1" "$e2" "$e3" "$e4" "$e5" "$e6"
    (( MEM_COMMITLIM > 0 )) && commit_pct=$(( 100 * MEM_COMMIT / MEM_COMMITLIM ))
    v_fmt_mem "$MEM_COMMIT"; e1=$FMTM
    v_fmt_mem "$MEM_COMMITLIM"; e2=$FMTM
    v_fmt_mem "$MEM_SWAPCACHED"; e3=$FMTM
    v_rate $(( ${SWAPIN_PAGES:-0} * PAGE_KB * 1024 )) "$ELAPSED_NS"; v_fmt_b "$RATE"; e4=$FMTB
    v_rate $(( ${SWAPOUT_PAGES:-0} * PAGE_KB * 1024 )) "$ELAPSED_NS"; v_fmt_b "$RATE"; e5=$FMTB
    add 'MEM   commit %s / %s (%s%%)   swapcached %s   swap in/out %s/s / %s/s' \
      "$e1" "$e2" "$commit_pct" "$e3" "$e4" "$e5"
  fi
  local vu vt gu gt
  gpu_sysfs_v; vu=$GPU_VU; vt=$GPU_VT; gu=$GPU_GU; gt=$GPU_GT
  local vram_pct=$(( vt ? 100 * vu / vt : 0 )) gtt_pct=$(( gt ? 100 * gu / gt : 0 ))
  local barg="" hv v1 v2 v3 gtv
  if (( vt <= 0 )); then
    # driver does not expose mem_info_vram_total (old radeon, vfio, headless...)
    local u1 u2
    gpu_sysfs_v
    v_fmt_b "$GPU_VU"; u1=$FMTB
    v_fmt_b "$GPU_GU"; u2=$FMTB
    read_temp_v "$HWM_GPU"; v_temp "$TEMP"
    add 'GPU   %s   VRAM n/a (driver has no mem_info_vram_total)%s%s' \
      "${GPU_MODEL:-unknown GPU}" "${GPU_GU:+   GTT $u2}" "$( [[ -n $TEMP ]] && printf '   temp %s' "$TEMPC" )"
    add '%s      read %s used   check: ls /sys/class/drm/card*/device/mem_info_vram_total%s' "$C_DIM" "$u1" "$C_RESET"
  else
  if (( BARS )); then v_bar "$vram_pct" 12; barg="$BAR "; fi
  v_hcp "$vram_pct"; hv=$HCP
  v_fmt_b "$vu"; v1=$FMTB
  v_fmt_b "$vt"; v2=$FMTB
  v_fmt_b "$gu"; v3=$FMTB
  read_temp_v "$HWM_GPU"; v_temp "$TEMP"; gtv=$TEMPC
  local gb="" gbusy
  gpu_busy_v; gbusy=$GBUSY
  if [[ -n $gbusy ]]; then v_hcp "$gbusy"; gb="   busy $HCP%"; fi
  add 'GPU   %sVRAM %s%%   %s / %s   GTT %s (%s%%)   temp %s%s' \
    "$barg" "$hv" "$v1" "$v2" "$v3" "$gtt_pct" "$gtv" "$gb"
  fi
  if (( GPU_TOP )) && (( ${#CUR_GPU_PIDS[@]} > 0 )); then
    local -A engsum=()
    local epid ename ens i
    local -a pairs=()
    for epid in "${CUR_GPU_PIDS[@]}"; do
      read -r -a pairs <<< "${ENG_DELTA[$epid]:-}"
      for (( i = 0; i + 1 < ${#pairs[@]}; i += 2 )); do
        ename=${pairs[i]}; ens=${pairs[i+1]}
        [[ -n $ename && $ens =~ ^[0-9]+$ ]] || continue
        engsum[$ename]=$(( ${engsum[$ename]:-0} + ens ))
      done
    done
    if (( ${#engsum[@]} > 0 )); then
      local eline=""
      while read -r ename ens; do
        v_pct10 "$ens" "$ELAPSED_NS"
        eline+="$ename $(v_hcp "$PCT10"; printf '%s' "$HCP")%   "
      done < <(for ename in "${!engsum[@]}"; do echo "$ename ${engsum[$ename]}"; done | sort -k2,2rn | head -4)
      add 'ENGINE  %s' "$eline"
    fi
  fi
  local d1 d2
  v_rate $(( CUR_DISK_R - PRE_DISK_R )) "$ELAPSED_NS" 512; v_fmt_b "$RATE"; d1=$FMTB
  v_rate $(( CUR_DISK_W - PRE_DISK_W )) "$ELAPSED_NS" 512; v_fmt_b "$RATE"; d2=$FMTB
  add 'DISK  %s   read %s/s   write %s/s' "$ROOT_DISK" "$d1" "$d2"
  local netline="" iface rxd txd
  while read -r iface rxd txd; do
    [[ -n $iface ]] || continue
    if (( rxd > 0 || txd > 0 )) || { [[ -z $netline && $iface == "$DEFAULT_IFACE" ]]; }; then
      local rxs txs
      v_rate "$rxd" "$ELAPSED_NS"; v_fmt_b "$RATE"; rxs=$FMTB
      v_rate "$txd" "$ELAPSED_NS"; v_fmt_b "$RATE"; txs=$FMTB
      netline+="$iface rx $rxs/s  tx $txs/s   "
    fi
  done < <(
    for iface in "${!CUR_NET_RX[@]}"; do
      rxd=$(( ${CUR_NET_RX[$iface]:-0} - ${PRE_NET_RX[$iface]:-${CUR_NET_RX[$iface]:-0}} ))
      txd=$(( ${CUR_NET_TX[$iface]:-0} - ${PRE_NET_TX[$iface]:-${CUR_NET_TX[$iface]:-0}} ))
      (( rxd < 0 )) && rxd=0
      (( txd < 0 )) && txd=0
      echo "$iface $(( rxd + txd )) $rxd $txd"
    done | sort -k2,2rn | cut -d' ' -f1,3,4
  )
  [[ -n $netline ]] || netline="idle"
  add 'NET   %s' "$netline"
  local tc tg tn
  read_temp_v "$HWM_CPU"; v_temp "$TEMP"; tc=$TEMPC
  read_temp_v "$HWM_GPU"; v_temp "$TEMP"; tg=$TEMPC
  read_temp_v "$HWM_NVME"; v_temp "$TEMP"; tn=$TEMPC
  add 'TEMP  CPU %s   GPU %s   NVMe %s' "$tc" "$tg" "$tn"
  add ''
  add '%sTOP CPU%s  (last %ss)' "$C_BOLD" "$C_RESET" "$INTERVAL"
  add '%s  %-8s %8s %10s  %s%s' "$C_DIM" PID CPU% RSS COMMAND "$C_RESET"
  local pid p10 pv ppad
  while read -r p10 pid; do
    [[ -n $pid ]] || continue
    v_tenths "$p10"; printf -v ppad '%8s' "$TENTHS"
    v_hcp "$ppad"
    rss_kb_v "$pid"; v_fmt_kib "$RSS_KB"
    proc_label_v "$pid"
    add '  %-8s %s %10s  %s' "$pid" "$HCP" "$FMTB" "$LABEL"
  done < <(
    for pid in "${!CUR_PROC_TICKS[@]}"; do
      [[ -n ${PRE_PROC_TICKS[$pid]+x} ]] || continue
      d=$(( CUR_PROC_TICKS[$pid] - PRE_PROC_TICKS[$pid] ))
      (( d > 0 )) && echo "$(( d * 1000 / e )) $pid"
    done | sort -rn | head -"$ROWS_CPU"
  )
  add ''
  add '%sTOP MEM%s  (RSS; swap shown for listed rows)' "$C_BOLD" "$C_RESET"
  add '%s  %-8s %10s %10s  %s%s' "$C_DIM" PID RSS SWAP COMMAND "$C_RESET"
  local mpid mrss mrv msv
  while read -r mpid mrss; do
    [[ -n $mpid && $mrss =~ ^[0-9]+$ ]] || continue
    v_fmt_mem "$mrss"; mrv=$FMTM
    proc_swap_kb_v "$mpid"; v_fmt_mem "$SWAP_KB"; msv=$FMTM
    proc_label_v "$mpid"
    add '  %-8s %10s %10s  %s' "$mpid" "$mrv" "$msv" "$LABEL"
  done < <(ps -eo pid=,rss= --sort=-rss 2>/dev/null | head -n "$ROWS_MEM")
  if (( GPU_TOP )) && (( ${#CUR_GPU_PIDS[@]} > 0 )); then
    add ''
    local engine_total=0
    for pid in "${CUR_GPU_PIDS[@]}"; do
      d=${ENG_TOTAL[$pid]:-0}
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
    local -a grows=()
    local gkey gv
    while read -r gkey gv pid; do
      [[ -n $pid ]] || continue
      grows+=("$gkey $gv $pid")
    done < <(
      for pid in "${CUR_GPU_PIDS[@]}"; do
        if (( use_engine )); then
          d=${ENG_TOTAL[$pid]:-0}
          echo "$d ${CUR_GPU_VRAM[$pid]:-0} $pid"
        else
          echo "${CUR_GPU_VRAM[$pid]:-0} 0 $pid"
        fi
      done | sort -k1,1rn -k2,2rn | head -"$ROWS_GPU"
    )
    # keep the biggest VRAM holder visible even while its engine is idle
    local top_vram_pid="" top_vram=0 v row seen=0
    for pid in "${CUR_GPU_PIDS[@]}"; do
      v=${CUR_GPU_VRAM[$pid]:-0}
      if (( v > top_vram )); then top_vram=$v; top_vram_pid=$pid; fi
    done
    if [[ -n $top_vram_pid ]]; then
      for row in "${grows[@]}"; do [[ ${row##* } == "$top_vram_pid" ]] && seen=1; done
      if (( ! seen )); then
        (( ${#grows[@]} >= ROWS_GPU )) && grows=("${grows[@]:0:$(( ROWS_GPU - 1 ))}")
        grows+=("0 $top_vram $top_vram_pid")
      fi
    fi
    for row in "${grows[@]}"; do
      set -- $row; gkey=$1; gv=$2; pid=$3
      if (( use_engine )); then
        local gpct gpad
        v_pct10 "$gkey" "$ELAPSED_NS"; gpct=$PCT10
        printf -v gpad '%8s' "$gpct"; v_hcp "$gpad"
        v_fmt_kib "${CUR_GPU_VRAM[$pid]:-0}"
        proc_label_v "$pid"
        add '  %-8s %s %10s  %s' "$pid" "$HCP" "$FMTB" "$LABEL"
      else
        v_fmt_kib "${CUR_GPU_VRAM[$pid]:-0}"
        proc_label_v "$pid"
        add '  %-8s %10s  %s' "$pid" "$FMTB" "$LABEL"
      fi
    done
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

gpu_sysfs_v() {  # sets GPU_VU/GPU_VT/GPU_GU/GPU_GT (bytes), no subshell
  GPU_VU=0; GPU_VT=0; GPU_GU=0; GPU_GT=0
  local line mu mt
  if [[ -n $GPU_DEV ]]; then
    read -r GPU_VU 2>/dev/null < "$GPU_DEV/mem_info_vram_used"
    read -r GPU_VT 2>/dev/null < "$GPU_DEV/mem_info_vram_total"
    read -r GPU_GU 2>/dev/null < "$GPU_DEV/mem_info_gtt_used"
    read -r GPU_GT 2>/dev/null < "$GPU_DEV/mem_info_gtt_total"
  elif (( NVIDIA )); then
    line=$(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader,nounits 2>/dev/null | head -1)
    if [[ -n $line ]]; then
      IFS=', ' read -r mu mt <<< "$line"
      GPU_VU=$(( mu * 1048576 )); GPU_VT=$(( mt * 1048576 ))
    fi
  fi
}

gpu_busy_v() {  # sets GBUSY (integer) or empty
  GBUSY=""
  if [[ -n $GPU_DEV && -r $GPU_DEV/gpu_busy_percent ]]; then
    read -r GBUSY 2>/dev/null < "$GPU_DEV/gpu_busy_percent" || GBUSY=""
    [[ $GBUSY =~ ^[0-9]+$ ]] && return
    GBUSY=""
  fi
  if (( NVIDIA )); then
    GBUSY=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -1)
    [[ $GBUSY =~ ^[0-9]+$ ]] || GBUSY=""
  fi
}

render_proc() {
  local pid=$1 e dt
  e=$(( ELAPSED_NS * CLK_TCK / 1000000000 )); (( e > 0 )) || e=1
  dt=$(( CUR_PTICKS - PRE_PTICKS ))
  local ncores=${#CUR_CORES[@]} cpu_pct barp=""
  v_pct10 "$dt" "$e"; cpu_pct=$PCT10
  if (( BARS )); then v_bar $(( dt * 100 / e )) 12; barp="$BAR "; fi
  proc_label_v "$pid"; local plabel=$LABEL
  rss_kb_v "$pid"; local rssv; v_fmt_mem "$RSS_KB"; rssv=$FMTM
  local swap_kb; swap_kb=$(proc_swap_kb "$pid"); v_fmt_mem "${swap_kb:-0}"; local swapv=$FMTM
  v_hcp "$cpu_pct"; local hcpu=$HCP
  v_cores2 "$dt" "$e"; local cores2v=$CORES2
  add 'PROC  %s%s%s (pid %s)   RSS %s   swap %s   threads %s' \
    "$C_BOLD" "$plabel" "$C_RESET" "$pid" "$rssv" "$swapv" "${#CUR_THREAD_TICKS[@]}"
  add 'CPU   %s%s%% (%s cores of %s)' "$barp" "$hcpu" "$cores2v" "$ncores"
  read_smaps_v "$pid"
  if (( SMAPS_RSS > 0 )); then
    local m1 m2 m3 m4 m5 m6
    v_fmt_mem "$SMAPS_RSS"; m1=$FMTM
    v_fmt_mem "$SMAPS_ANON"; m2=$FMTM
    v_fmt_mem "$SMAPS_SHARED"; m3=$FMTM
    v_fmt_mem "$SMAPS_PRIVATE"; m4=$FMTM
    v_fmt_mem "$SMAPS_PSS"; m5=$FMTM
    v_fmt_mem "$SMAPS_SWAP"; m6=$FMTM
    add 'MEM   rss %s (anon %s, shared %s, private %s)   pss %s   swap %s' "$m1" "$m2" "$m3" "$m4" "$m5" "$m6"
    if (( MEM_DETAIL )); then
      local n1 n2 n3 n4 n5
      v_fmt_mem "$SMAPS_PSS_ANON"; n1=$FMTM
      v_fmt_mem "$SMAPS_PSS_FILE"; n2=$FMTM
      v_fmt_mem "$SMAPS_SWAP_PSS"; n3=$FMTM
      v_fmt_mem "$SMAPS_LOCKED"; n4=$FMTM
      v_fmt_mem "$SMAPS_HUGE"; n5=$FMTM
      add 'MEM   pss-anon %s   pss-file %s   swapped-pss %s   locked %s   anon-huge %s' \
        "$n1" "$n2" "$n3" "$n4" "$n5"
    fi
  fi
  read_status_mem_v "$pid"
  if (( STA_VIRT > 0 )); then
    local s1 s2 s3 s4 s5 s6 s7
    v_fmt_mem "$STA_VIRT"; s1=$FMTM
    v_fmt_mem "$STA_PEAK"; s2=$FMTM
    v_fmt_mem "$STA_DATA"; s3=$FMTM
    v_fmt_mem "$STA_STK"; s4=$FMTM
    v_fmt_mem "$STA_EXE"; s5=$FMTM
    v_fmt_mem "$STA_LIB"; s6=$FMTM
    v_fmt_mem "$STA_PTE"; s7=$FMTM
    add 'MEM   virt %s   peak %s   data %s   stack %s   exe %s   lib %s   pte %s' "$s1" "$s2" "$s3" "$s4" "$s5" "$s6" "$s7"
  fi
  add '%sTHREADS%s  (top 5 by CPU; 100%% = one core)' "$C_BOLD" "$C_RESET"
  local tid p10 pv ppad trows=0
  while read -r p10 tid; do
    [[ -n $tid ]] || continue
    trows=$(( trows + 1 ))
    v_tenths "$p10"; printf -v ppad '%7s' "$TENTHS"; v_hcp "$ppad"
    add '  %s%%  %-8s %s' "$HCP" "$tid" "${CUR_THREAD_COMM[$tid]:-?}"
  done < <(
    for tid in "${!CUR_THREAD_TICKS[@]}"; do
      [[ -n ${PRE_THREAD_TICKS[$tid]+x} ]] || continue
      d=$(( CUR_THREAD_TICKS[$tid] - PRE_THREAD_TICKS[$tid] ))
      (( d > 0 )) && echo "$(( d * 1000 / e )) $tid"
    done | sort -rn | head -"$ROWS_CPU"
  )
  (( trows > 0 )) || add '  %s(no thread activity in this interval)%s' "$C_DIM" "$C_RESET"
  local vu vt gu gt
  gpu_sysfs_v; vu=$GPU_VU; vt=$GPU_VT; gu=$GPU_GU; gt=$GPU_GT
  if (( CUR_PV > 0 )); then
    local eng_pct pvram_pct eline="" ename ens
    engine_delta_v "$PRE_PENGINES" "$CUR_PENGINES"
    v_pct10 "$ENGTOTAL" "$ELAPSED_NS"; eng_pct=$PCT10
    pvram_pct=$(( vt ? 100 * (CUR_PV * 1024) / vt : 0 ))
    local -a epairs=() elines=()
    read -r -a epairs <<< "${ENGDELTA:-}"
    local ei
    for (( ei = 0; ei + 1 < ${#epairs[@]}; ei += 2 )); do
      [[ ${epairs[ei+1]} =~ ^[0-9]+$ ]] || continue
      elines+=("${epairs[ei]} ${epairs[ei+1]}")
    done
    if (( ${#elines[@]} > 0 )); then
      while read -r ename ens; do
        v_pct10 "$ens" "$ELAPSED_NS"; v_hcp "$PCT10"
        eline+="$ename $HCP%   "
      done < <(printf '%s\n' "${elines[@]}" | sort -k2,2rn | head -4)
    fi
    [[ -n $eline ]] || eline="idle   "
    v_hcp "$eng_pct"
    add 'GPU   engines %s total %s%%' "$eline" "$HCP"
    v_fmt_kib "$CUR_PV"; local pvv=$FMTB; v_fmt_b "$vt"; local vtv=$FMTB
    v_hcp "$pvram_pct"; local hpv=$HCP
    v_fmt_kib "$CUR_PGT"; local pgv=$FMTB; v_fmt_kib "$CUR_PEV"; local pev=$FMTB
    add 'GPU   VRAM %s/%s (%s%%)   GTT %s   evicted %s' \
      "$pvv" "$vtv" "$hpv" "$pgv" "$pev"
  else
    local v1 v2 v3
    v_fmt_b "$vu"; v1=$FMTB; v_fmt_b "$vt"; v2=$FMTB; v_fmt_b "$gu"; v3=$FMTB
    add 'GPU   no DRM client found   system VRAM %s / %s   GTT %s' "$v1" "$v2" "$v3"
  fi
  local rd wr
  v_rate $(( CUR_PREAD - PRE_PREAD )) "$ELAPSED_NS"; v_fmt_b "$RATE"; rd=$FMTB
  v_rate $(( CUR_PWRITE - PRE_PWRITE )) "$ELAPSED_NS"; v_fmt_b "$RATE"; wr=$FMTB
  add 'DISK  read %s/s   write %s/s' "$rd" "$wr"
  local stotal sest slis sudp
  read -r stotal sest slis sudp < <(proc_sockets "$pid")
  add 'NET   sockets %s (established %s, listen %s, udp %s)' "$stotal" "$sest" "$slis" "$sudp"
  local sbusy=$(( (CUR_CPU_TOTAL-CUR_CPU_IDLE) - (PRE_CPU_TOTAL-PRE_CPU_IDLE) )) sdt=$(( CUR_CPU_TOTAL - PRE_CPU_TOTAL ))
  local sb_pct
  v_pct10 "$sbusy" "$sdt"; sb_pct=$PCT10
  read_mem
  local shcpu sc2 smem sswap stc stg
  v_hcp "$sb_pct"; shcpu=$HCP
  v_cores2 "$sbusy" "$e"; sc2=$CORES2
  v_fmt_mem "$MEM_AVAIL"; smem=$FMTM
  v_fmt_mem $(( SWAP_TOTAL - SWAP_FREE )); sswap=$FMTM
  read_temp_v "$HWM_CPU"; v_temp "$TEMP"; stc=$TEMPC
  read_temp_v "$HWM_GPU"; v_temp "$TEMP"; stg=$TEMPC
  add 'SYS   CPU %s%% (%s/%s)   RAM avail %s   swap %s   TEMP CPU %s GPU %s' \
    "$shcpu" "$sc2" "$ncores" "$smem" "$sswap" "$stc" "$stg"
}

render_footer() {
  add ''
  add '%sVRAM near 100%% + GTT/evicted rising = texture thrash;  gfx near 100%% = GPU-bound;%s' "$C_DIM" "$C_RESET"
  (( TERM_LINES >= 28 )) && add '%sone thread near 100%% while cores idle = single-core bound.  Ctrl-C quits.%s' "$C_DIM" "$C_RESET"
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
  read_mem
  MEM_USED_KIB=$(( MEM_TOTAL - MEM_AVAIL ))
  if [[ -n ${PRE_MEM_KIB:-} ]]; then MEM_DELTA_KIB=$(( MEM_USED_KIB - PRE_MEM_KIB )); else MEM_DELTA_KIB=0; fi
  PRE_MEM_KIB=$MEM_USED_KIB
  read_vmstat_swap
  if [[ -n ${PRE_PSWPIN:-} ]]; then
    SWAPIN_PAGES=$(( PSWPIN - PRE_PSWPIN )); SWAPOUT_PAGES=$(( PSWPOUT - PRE_PSWPOUT ))
    (( SWAPIN_PAGES < 0 )) && SWAPIN_PAGES=0
    (( SWAPOUT_PAGES < 0 )) && SWAPOUT_PAGES=0
  else
    SWAPIN_PAGES=0; SWAPOUT_PAGES=0
  fi
  PRE_PSWPIN=$PSWPIN; PRE_PSWPOUT=$PSWPOUT
  if [[ -z $TARGET ]]; then
    ENG_DELTA=(); ENG_TOTAL=()
    for pid in "${CUR_GPU_PIDS[@]}"; do
      engine_delta_v "${PRE_GPU_ENGINES[$pid]:-}" "${CUR_GPU_ENGINES[$pid]:-}"
      ENG_DELTA[$pid]=$ENGDELTA
      ENG_TOTAL[$pid]=$ENGTOTAL
    done
  fi
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
    PRE_NET_RX=(); for k in "${!CUR_NET_RX[@]}"; do PRE_NET_RX[$k]=${CUR_NET_RX[$k]}; done
    PRE_NET_TX=(); for k in "${!CUR_NET_TX[@]}"; do PRE_NET_TX[$k]=${CUR_NET_TX[$k]}; done
  fi
  PRE_NS=$CUR_NS
done
cleanup
