#!/bin/bash
# =============================================================================
# HBA Mode SATA SSD Pre-Test Tuning Script
# Target OS  : Rocky Linux 8.10 (Green Obsidian)
# Drives     : /dev/sda – /dev/sdx (auto-detected)
# Guide ref  : Adaptec Smart Adapter Performance Guide (Answer ID 17474)
# Usage      : sudo bash hba_sata_pretune.sh [--dry-run] [--revert] [--yes]
#   --dry-run   Show what would be done without making any changes
#   --revert    Restore conservative OS defaults
#   --yes       Skip all step confirmations (auto-accept)
# =============================================================================

set -euo pipefail

# ── Colour helpers ─────────────────────────────────────────────────────────────
RED='\033[0;31m'; YEL='\033[1;33m'; GRN='\033[0;32m'
CYN='\033[0;36m'; BLD='\033[1m'; DIM='\033[2m'; MAG='\033[0;35m'; RST='\033[0m'

info()    { echo -e "${CYN}  i  INFO${RST}    $*"; }
ok()      { echo -e "${GRN}  v  OK${RST}      $*"; }
warn()    { echo -e "${YEL}  !  WARN${RST}    $*"; }
err()     { echo -e "${RED}  x  ERROR${RST}   $*"; }
reason()  { echo -e "${MAG}  >  WHY${RST}     ${DIM}$*${RST}"; }
applied() { echo -e "${GRN}  *  APPLY${RST}   $*"; }

hdr() {
  local step="$1"; shift
  echo ""
  echo -e "${BLD}${CYN}+-------------------------------------------------------------+${RST}"
  echo -e "${BLD}${CYN}|  Step ${step}: $*${RST}"
  echo -e "${BLD}${CYN}+-------------------------------------------------------------+${RST}"
}

# ── Argument parsing ───────────────────────────────────────────────────────────
DRY=false
REVERT=false
AUTO_YES=false

for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY=true
  [[ "$arg" == "--revert"  ]] && REVERT=true
  [[ "$arg" == "--yes"     ]] && AUTO_YES=true
done

# ── Root check ─────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  err "This script must be run as root.  Use:  sudo bash $0"
  exit 1
fi

LOG="/var/log/hba_sata_pretune_$(date +%Y%m%d_%H%M%S).log"
date >> "$LOG"

# ── Apply or echo helper ───────────────────────────────────────────────────────
run() {
  if $DRY; then
    echo -e "  ${YEL}  [DRY-RUN]${RST} $*"
  else
    eval "$@" >> "$LOG" 2>&1 || warn "Command returned non-zero: $*"
  fi
}

# ── Step confirmation prompt ───────────────────────────────────────────────────
confirm_step() {
  $AUTO_YES && return 0
  $DRY      && return 0
  echo ""
  echo -e "${BLD}  Continue with this step? ${RST}[${GRN}Y${RST}]es / [${RED}n${RST}]o / [${YEL}q${RST}]uit"
  read -r -p "  -> " answer
  case "${answer,,}" in
    ''|y|yes) return 0 ;;
    q|quit)   echo ""; echo -e "${YEL}Aborted by user.${RST}"; exit 0 ;;
    *)        warn "Step skipped."; return 1 ;;
  esac
}

# ── Detect drives (skip OS mounts) ────────────────────────────────────────────
detect_drives() {
  local found=()
  for dev in /dev/sd[a-z] /dev/sd[a-z][a-z]; do
    [[ -b "$dev" ]] || continue
    if lsblk -no MOUNTPOINT "$dev" 2>/dev/null | grep -qE '^/$|^/boot$'; then
      warn "Skipping $dev — OS mount point detected."
      continue
    fi
    found+=("$dev")
  done
  echo "${found[@]:-}"
}

# =============================================================================
# REVERT MODE
# =============================================================================
if $REVERT; then
  echo ""
  echo -e "${BLD}${YEL}REVERT MODE — Restoring conservative OS defaults${RST}"
  DRIVES=($(detect_drives))
  for dev in "${DRIVES[@]}"; do
    DEV=$(basename "$dev")
    run "echo mq-deadline > /sys/block/${DEV}/queue/scheduler"
    run "echo 128         > /sys/block/${DEV}/queue/read_ahead_kb"
    run "echo 128         > /sys/block/${DEV}/queue/nr_requests"
    run "echo 1           > /sys/block/${DEV}/queue/rq_affinity"
    run "echo 0           > /sys/block/${DEV}/queue/nomerges"
    ok "Reverted $dev"
  done
  for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -f "$cpu" ]] && run "echo powersave > $cpu"
  done
  run "sysctl -w vm.swappiness=60               > /dev/null"
  run "sysctl -w vm.dirty_ratio=20              > /dev/null"
  run "sysctl -w vm.dirty_background_ratio=10   > /dev/null"
  run "sysctl -w vm.dirty_expire_centisecs=500  > /dev/null"
  run "sysctl -w vm.dirty_writeback_centisecs=500 > /dev/null"
  ok "Kernel VM parameters reverted."
  echo ""
  ok "Revert complete."
  exit 0
fi

# =============================================================================
# BANNER
# =============================================================================
clear
echo ""
echo -e "${BLD}${CYN}+===============================================================+${RST}"
echo -e "${BLD}${CYN}|    HBA SATA SSD Pre-Test Tuning  --  Rocky Linux 8.10         |${RST}"
echo -e "${BLD}${CYN}|    Adaptec Smart Adapter Performance Guide  (ID 17474)         |${RST}"
echo -e "${BLD}${CYN}+===============================================================+${RST}"
echo ""
$DRY      && warn "DRY-RUN MODE active -- no changes will be made."
$AUTO_YES && info "Auto-yes mode -- all steps will proceed without prompts."
info "Log file: $LOG"
echo ""

# =============================================================================
# PRE-FLIGHT: Detect drives
# =============================================================================
echo -e "${BLD}Detecting SATA block devices ...${RST}"
DRIVES=($(detect_drives))

if [[ ${#DRIVES[@]} -eq 0 ]]; then
  err "No eligible /dev/sd* block devices found (all may be OS drives)."
  exit 1
fi
ok "Found ${#DRIVES[@]} drive(s): ${DRIVES[*]}"

# =============================================================================
# WORKLOAD MODE SELECTION
# =============================================================================
echo ""
echo -e "${BLD}${CYN}+-------------------------------------------------------------+${RST}"
echo -e "${BLD}${CYN}|  Workload Mode Selection                                    |${RST}"
echo -e "${BLD}${CYN}+-------------------------------------------------------------+${RST}"
echo ""
reason "Some block device IO parameters differ between sequential and random"
reason "workloads. Sequential mode is the default (optimal for throughput tests)."
reason "Random mode disables read-ahead and IO merging to expose true 4KB IOPS."
echo ""
echo -e "  ${BLD}Default: Sequential workload tuning${RST}"
echo -e "    read_ahead_kb = 128   (OS pre-fetches ahead -- benefits sequential streams)"
echo -e "    nomerges      = 0     (allow IO merging -- coalesces adjacent requests)"
echo ""
echo -e "  ${YEL}Optional: Random workload tuning${RST}"
echo -e "    read_ahead_kb = 0     (disable pre-fetch -- random IOs have no locality)"
echo -e "    nomerges      = 2     (disable merging -- preserves true 4KB random IO pattern)"
echo ""

RANDOM_MODE=false
if ! $AUTO_YES; then
  read -r -p "  Optimise for RANDOM workloads instead of SEQUENTIAL? [y/N] -> " wl_choice
  [[ "${wl_choice,,}" =~ ^(y|yes)$ ]] && RANDOM_MODE=true
fi

if $RANDOM_MODE; then
  RA_VAL=0;   NM_VAL=2
  echo -e "  ${YEL}-> Random workload mode selected.${RST}"
else
  RA_VAL=128; NM_VAL=0
  echo -e "  ${GRN}-> Sequential workload mode selected (default).${RST}"
fi

# =============================================================================
# STEP 1 -- Dependency: sdparm
# =============================================================================
hdr 1 "Dependency Check -- sdparm"

reason "sdparm reads/writes SCSI mode page parameters directly to each drive."
reason "We need it to send WCE (Write Cache Enable) to the drive's internal mode"
reason "page -- the only reliable way to control drive-level write cache in HBA"
reason "mode without a RAID manager present."

if confirm_step; then
  if ! command -v sdparm &>/dev/null; then
    info "sdparm not found -- installing via dnf..."
    run "dnf install -y sdparm"
    ok "sdparm installed."
  else
    ok "sdparm already installed: $(sdparm --version 2>&1 | head -1)"
  fi
fi

# =============================================================================
# STEP 2 -- Enable Drive Write Cache (WCE)
# =============================================================================
hdr 2 "Enable Drive Write Cache (WCE) on All SATA SSDs"

reason "SATA SSD DDR write caches are non-volatile (flush-safe on power loss)"
reason "and safe to enable. With write cache ON, the drive acknowledges writes"
reason "after buffering in fast DRAM instead of waiting for flash commit -- this"
reason "dramatically improves write IOPS and latency at low queue depths."
reason "Guide: 'verify that the drive write cache is enabled for best performance.'"
reason "The -S flag saves the setting persistently across reboots."

if confirm_step; then
  for dev in "${DRIVES[@]}"; do
    info "Enabling write cache on $dev ..."
    if $DRY; then
      echo -e "  ${YEL}  [DRY-RUN]${RST} sdparm -s WCE=1 -S $dev"
    else
      if sdparm -s WCE=1 -S "$dev" >> "$LOG" 2>&1; then
        ok "WCE enabled on $dev"
      else
        warn "sdparm failed on $dev (may already be set or drive does not support WCE)"
      fi
    fi
  done

  if ! $DRY; then
    echo ""
    info "Verifying WCE state:"
    for dev in "${DRIVES[@]}"; do
      WCE=$(sdparm -g WCE "$dev" 2>/dev/null | awk '{print $NF}' || echo "?")
      STATUS_ICON=$( [ "$WCE" = "1" ] && echo "${GRN}v${RST}" || echo "${RED}x${RST}" )
      echo -e "    ${GRN}$dev${RST}  WCE = ${BLD}$WCE${RST}  $STATUS_ICON"
    done
  fi
fi

# =============================================================================
# STEP 3 -- CPU Performance Governor
# =============================================================================
hdr 3 "Set CPU Governor to 'performance'"

reason "Rocky Linux 8 defaults to the 'powersave' CPU frequency governor which"
reason "dynamically scales CPU clock speed down to save energy. Under benchmark"
reason "load it may not ramp up frequency fast enough, introducing artificial"
reason "latency spikes between IO completions. Setting 'performance' pins every"
reason "core at max clock frequency ensuring consistent, repeatable IO latency --"
reason "a prerequisite for accurate benchmarks."
reason "Guide: 'Verify server is set to maximum power/performance mode.'"

if confirm_step; then
  if ! command -v cpupower &>/dev/null; then
    info "Installing kernel-tools (provides cpupower)..."
    run "dnf install -y kernel-tools"
  fi
  run "cpupower frequency-set -g performance > /dev/null 2>&1"

  if ! $DRY; then
    GOV=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")
    [[ "$GOV" == "performance" ]] && ok "CPU governor: ${BLD}performance${RST}" \
                                  || warn "Governor is still: $GOV"
  fi

  if [[ -f /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    info "Intel pstate detected -- ensuring turbo boost is ON..."
    run "echo 0 > /sys/devices/system/cpu/intel_pstate/no_turbo"
    ok "Turbo boost enabled."
  fi
fi

# =============================================================================
# STEP 4 -- tuned Profile + C-State Management
# =============================================================================
hdr 4 "OS Power Profile -- tuned throughput-performance + disable deep C-states"

reason "The 'tuned' daemon manages system-wide performance profiles. Rocky Linux"
reason "defaults to 'balanced' which enables deep CPU idle C-states (C3/C6/C7)."
reason "Waking from deep C-states adds microseconds of latency to every IO"
reason "completion interrupt -- enough to measurably suppress IOPS at high queue"
reason "depths. 'throughput-performance' disables deep C-states and tunes kernel"
reason "parameters for maximum IO throughput."

if confirm_step; then
  if systemctl is-active --quiet tuned 2>/dev/null; then
    CURRENT_PROFILE=$(tuned-adm active 2>/dev/null | awk '{print $NF}' || echo "unknown")
    info "Current tuned profile: ${BLD}$CURRENT_PROFILE${RST}"
    run "tuned-adm profile throughput-performance"
    ok "tuned profile -> ${BLD}throughput-performance${RST}"
  else
    warn "tuned service not running -- skipping tuned profile."
  fi

  if command -v cpupower &>/dev/null; then
    info "Disabling CPU idle states deeper than C1 to reduce interrupt wake latency..."
    run "cpupower idle-set -D 2 > /dev/null 2>&1"
    ok "Deep C-states (C2 and beyond) disabled."
  fi
fi

# =============================================================================
# STEP 5 -- I/O Scheduler: none
# =============================================================================
hdr 5 "Set I/O Scheduler to 'none' on each drive"

reason "The Linux block scheduler (mq-deadline, bfq) reorders and merges IOs"
reason "before issuing them to the driver. Useful for spinning HDDs where"
reason "reordering reduces seek time. For fast SSDs with no seek penalty, the"
reason "scheduler adds CPU overhead and latency with zero benefit. Setting it to"
reason "'none' passes IOs directly from OS to driver in submission order, letting"
reason "the adapter firmware manage queueing natively."
reason "Guide: 'For SSDs, set the scheduler to none.'"

if confirm_step; then
  for dev in "${DRIVES[@]}"; do
    DEV=$(basename "$dev")
    SCHED_PATH="/sys/block/${DEV}/queue/scheduler"
    if [[ -f "$SCHED_PATH" ]]; then
      CURRENT=$(cat "$SCHED_PATH" 2>/dev/null | grep -oP '\[\K[^\]]+' || echo "?")
      if [[ "$CURRENT" == "none" ]]; then
        ok "$dev  already set to 'none'"
      else
        info "$dev  current: ${BLD}$CURRENT${RST} -> changing to none"
        run "echo none > $SCHED_PATH"
        applied "$dev  scheduler -> ${BLD}none${RST}"
      fi
    else
      warn "Scheduler sysfs path not found for $dev"
    fi
  done
fi

# =============================================================================
# STEP 6 -- SCSI Block Multi-Queue (MQ)
# =============================================================================
hdr 6 "Verify SCSI Block Multi-Queue (MQ)"

reason "Older kernels routed all block-layer IO through a single CPU core,"
reason "creating a bottleneck when IOPS from multiple fast SSDs exceeded what one"
reason "core could process. SCSI Block MQ distributes IO submission and completion"
reason "work across multiple CPU cores -- one queue per CPU core -- eliminating"
reason "this bottleneck. The guide says to explicitly verify it is enabled."
reason "Without MQ, results from multiple SSDs will be CPU-bound and artificially"
reason "low regardless of how fast the drives are."

if confirm_step; then
  MQ_VAL=$(cat /sys/module/scsi_mod/parameters/use_blk_mq 2>/dev/null || echo "N")
  info "Current use_blk_mq value: ${BLD}$MQ_VAL${RST}"

  if [[ "$MQ_VAL" == "Y" || "$MQ_VAL" == "1" ]]; then
    ok "SCSI Block MQ is already enabled."
  else
    warn "SCSI Block MQ is NOT enabled on the running kernel."
    if ! grep -q "scsi_mod.use_blk_mq=1" /etc/default/grub 2>/dev/null; then
      info "Adding scsi_mod.use_blk_mq=1 to /etc/default/grub ..."
      run "sed -i 's/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"scsi_mod.use_blk_mq=1 /' /etc/default/grub"
      run "grub2-mkconfig -o /boot/grub2/grub.cfg"
      warn "Grub updated -- REBOOT REQUIRED before MQ takes effect."
    else
      info "Entry already in grub config -- reboot may still be needed."
    fi
  fi
fi

# =============================================================================
# STEP 7 -- Block Device Queue Parameters
# =============================================================================
hdr 7 "Tune Block Device Queue Parameters (per drive)"

reason "nr_requests=1024: The OS queue depth -- how many IOs can be outstanding"
reason "  in the block layer before back-pressure reaches applications. Default"
reason "  is 128. For high-IOPS SSDs we raise this to 1024 so the benchmark can"
reason "  keep the adapter fully saturated with outstanding requests."
echo ""
reason "rq_affinity=2: Forces IO completions to be processed on the exact same"
reason "  CPU core that submitted the request. Prevents cache-line bouncing"
reason "  between cores (IO context stays in L1/L2 cache). The guide calls this"
reason "  'CPU affinity' -- keeping user thread and kernel IO path co-located"
reason "  minimises round-trip latency and improves IOPS."
echo ""
reason "max_sectors_kb=512: Sets max single IO size the OS will issue. Aligning"
reason "  this to the benchmark IO size prevents the OS from silently splitting"
reason "  large IOs into smaller pieces, which would inflate IOPS and understate"
reason "  per-IO latency."
echo ""

if $RANDOM_MODE; then
  reason "nomerges=2 (RANDOM): Disables all IO merging in the block layer."
  reason "  For 4KB random workloads adjacent requests are statistically rare."
  reason "  Merging wastes CPU checking adjacency and distorts the random IO"
  reason "  pattern -- making the workload look more sequential than it really is."
  echo ""
  reason "read_ahead_kb=0 (RANDOM): Disables OS read-ahead entirely."
  reason "  Random workloads have no spatial locality -- read-ahead fetches data"
  reason "  that will never be used, wasting drive bandwidth and cache space."
else
  reason "nomerges=0 (SEQUENTIAL): Allows OS to merge adjacent IOs into larger"
  reason "  requests before issuing to the driver. For sequential workloads,"
  reason "  consecutive writes can be coalesced into larger IOs, improving"
  reason "  protocol efficiency and reducing per-IO overhead on the adapter link."
  echo ""
  reason "read_ahead_kb=128 (SEQUENTIAL): Tells the OS to pre-fetch 128KB ahead"
  reason "  of each read. Sequential reads have strong spatial locality -- data"
  reason "  at address N is very likely followed by N+4K. Read-ahead hides"
  reason "  future IO latency by fetching data before the application asks."
fi

if confirm_step; then
  for dev in "${DRIVES[@]}"; do
    DEV=$(basename "$dev")
    B="/sys/block/${DEV}/queue"
    info "Tuning $dev ..."

    [[ -f "$B/nr_requests"    ]] && { run "echo 1024   > $B/nr_requests";      applied "  $dev  nr_requests    -> 1024"; }
    [[ -f "$B/rq_affinity"    ]] && { run "echo 2      > $B/rq_affinity";      applied "  $dev  rq_affinity    -> 2 (strict per-CPU completion)"; }
    [[ -f "$B/nomerges"       ]] && { run "echo $NM_VAL > $B/nomerges";        applied "  $dev  nomerges       -> $NM_VAL"; }
    [[ -f "$B/read_ahead_kb"  ]] && { run "echo $RA_VAL > $B/read_ahead_kb";   applied "  $dev  read_ahead_kb  -> ${RA_VAL} KB"; }
    [[ -f "$B/max_sectors_kb" ]] && { run "echo 512    > $B/max_sectors_kb";   applied "  $dev  max_sectors_kb -> 512 KB"; }
  done
fi

# =============================================================================
# STEP 8 -- IRQ / Interrupt Distribution
# =============================================================================
hdr 8 "IRQ Balance -- Distribute Interrupts Across CPU Cores"

reason "Every IO completion fires a hardware interrupt from the adapter to the CPU."
reason "Without irqbalance, all interrupts may land on CPU core 0 creating a"
reason "bottleneck. The guide instructs:"
reason "  'verify OS is distributing interrupts across all available CPU cores.'"
reason "irqbalance dynamically reassigns IRQ affinities based on load, preventing"
reason "any single core from becoming the interrupt bottleneck. Critical when"
reason "multiple SSDs complete IOs simultaneously and compete for CPU attention."

if confirm_step; then
  if ! rpm -q irqbalance &>/dev/null; then
    info "Installing irqbalance..."
    run "dnf install -y irqbalance"
  fi
  STATUS=$(systemctl is-active irqbalance 2>/dev/null || echo "inactive")
  if [[ "$STATUS" != "active" ]]; then
    run "systemctl enable --now irqbalance"
    ok "irqbalance started and enabled."
  else
    ok "irqbalance already running."
  fi

  if ! $DRY; then
    echo ""
    info "Current interrupt distribution (smartpqi driver):"
    if grep -q smartpqi /proc/interrupts 2>/dev/null; then
      grep smartpqi /proc/interrupts | head -10
    else
      warn "No smartpqi entries in /proc/interrupts yet (adapter may not be under load)."
      info "Monitor during benchmark with:  watch -n1 'grep smartpqi /proc/interrupts'"
    fi
  fi
fi

# =============================================================================
# STEP 9 -- NUMA Topology
# =============================================================================
hdr 9 "NUMA Topology -- Verify Adapter is on Near NUMA Node"

reason "On dual-socket servers, PCIe lanes are split between two NUMA nodes. If"
reason "your FIO process runs on CPU 0 but the adapter is wired to CPU 1's PCIe"
reason "lanes, every IO crosses the QPI/UPI inter-socket bus. The guide warns"
reason "this can cause up to a 20% IOPS reduction. This step shows your NUMA"
reason "layout so you can verify the adapter's NUMA node matches the node you"
reason "plan to run FIO on. Single-socket systems are unaffected."

if confirm_step; then
  if ! command -v numactl &>/dev/null; then
    info "Installing numactl..."
    run "dnf install -y numactl"
  fi

  if ! $DRY; then
    echo ""
    info "NUMA hardware topology:"
    numactl -H
    echo ""
    info "Locating smartpqi adapter NUMA node:"
    FOUND_ADAPTER=false
    for pci_dev in /sys/bus/pci/devices/*/; do
      if [[ -f "${pci_dev}driver/module" ]]; then
        driver=$(basename "$(readlink "${pci_dev}driver/module")" 2>/dev/null || echo "")
        if [[ "$driver" == "smartpqi" ]]; then
          node=$(cat "${pci_dev}numa_node" 2>/dev/null || echo "?")
          pci=$(basename "$pci_dev")
          echo -e "    ${GRN}Adapter PCI ${pci}${RST}  ->  NUMA node ${BLD}${node}${RST}"
          FOUND_ADAPTER=true
        fi
      fi
    done
    $FOUND_ADAPTER || warn "smartpqi adapter not found in /sys/bus/pci -- check manually with: lspci -vv"
    echo ""
    info "If NUMA node is -1, the system is single-socket -- no action needed."
    info "To pin FIO to a specific NUMA node:  numactl --cpunodebind=N fio <config>"
  fi
fi

# =============================================================================
# STEP 10 -- Kernel VM Parameters
# =============================================================================
hdr 10 "Kernel VM Parameters -- swappiness and dirty page ratios"

reason "vm.swappiness=1: Prevents the kernel from swapping memory to disk during"
reason "  the benchmark. Any swap IO competes with and corrupts your results."
reason "  Setting to 1 avoids swapping without fully disabling it as a safety net."
echo ""
reason "vm.dirty_ratio=5 / vm.dirty_background_ratio=2: Limit how much dirty"
reason "  (unwritten) data accumulates in the page cache before forcing a flush."
reason "  Large dirty buffers cause burst write spikes that look like performance"
reason "  drops mid-benchmark. Tighter ratios produce more consistent, steady-"
reason "  state write behaviour -- closer to what the drive actually sustains."
echo ""
reason "vm.dirty_expire / dirty_writeback = 100 cs (1 second): Dirty pages older"
reason "  than 1 second are written back; writeback daemon runs every 1 second."
reason "  Prevents the OS from deferring writes long enough to create a backlog"
reason "  that distorts sequential write results during long benchmark runs."

if confirm_step; then
  run "sysctl -w vm.swappiness=1                    > /dev/null"
  run "sysctl -w vm.dirty_ratio=5                   > /dev/null"
  run "sysctl -w vm.dirty_background_ratio=2         > /dev/null"
  run "sysctl -w vm.dirty_expire_centisecs=100       > /dev/null"
  run "sysctl -w vm.dirty_writeback_centisecs=100    > /dev/null"
  ok "vm.swappiness -> 1"
  ok "vm.dirty_ratio -> 5  |  dirty_background_ratio -> 2"
  ok "dirty_expire / dirty_writeback -> 100 cs (1 second)"
fi

# =============================================================================
# STEP 11 -- Adapter Status via arcconf
# =============================================================================
hdr 11 "Adapter Status -- Verify 'Optimal' via arcconf"

reason "The adapter must report 'Optimal' before any test. A degraded, faulted,"
reason "or rebuilding controller silently produces wrong results or masks a"
reason "hardware problem. The guide states:"
reason "  'Verify adapter is functioning normally -- status should be Optimal.'"
reason "In HBA mode, also verify all drives show as 'Online' and no error events"
reason "are pending in the adapter event log."

if confirm_step; then
  if command -v arcconf &>/dev/null; then
    if ! $DRY; then
      echo ""
      info "Adapter controller info:"
      arcconf GETCONFIG 1 AD 2>/dev/null \
        | grep -E "Controller Status|Controller Mode|Firmware|Driver|Temperature" || true
      echo ""
      info "Physical drive status:"
      arcconf GETCONFIG 1 PD 2>/dev/null \
        | grep -E "State|Drive|Vendor|Model|Size" | head -40 || true
    fi
  else
    warn "arcconf not found in PATH."
    warn "Download from start.adaptec.com and run manually:"
    warn "  arcconf GETCONFIG 1 AD   ->  Controller Status should be: Optimal"
    warn "  arcconf GETCONFIG 1 PD   ->  All drives should show: Online"
  fi
fi

# =============================================================================
# STEP 12 -- PCIe Link Speed Verification
# =============================================================================
hdr 12 "PCIe Link Speed -- Verify Gen3 x8 at Correct Width and Speed"

reason "The guide requires the adapter in a PCIe Gen3 x8 slot at full rated speed."
reason "PCIe link negotiation can silently downgrade to Gen2 or x4 width if the"
reason "slot does not support Gen3, another card forced a lower TLP size, or there"
reason "is a signal integrity issue. A Gen3 x8 -> Gen2 x8 downgrade halves"
reason "available PCIe bandwidth and will cap sequential throughput well below the"
reason "drive topology capability -- causing confusing low MBps results."
reason "Guide: 'adapter should be in PCIe Gen3 x8 slot, TLP block size = 256B.'"

if confirm_step; then
  if ! $DRY; then
    echo ""
    info "Adaptec adapter PCIe link status:"
    lspci -vv 2>/dev/null \
      | awk '/[Ss]mart|[Pp][Qq][Ii]|[Aa]daptec/ { found=1; count=0 }
             found && /LnkCap|LnkSta|Speed|Width/ { print; count++ }
             count==4 { found=0 }' \
      | head -20

    echo ""
    info "Expected:  LnkCap Speed 8GT/s (Gen3), Width x8"
    info "           LnkSta Speed 8GT/s,          Width x8  <- must match LnkCap"
    warn "If LnkSta shows lower speed/width than LnkCap, move adapter to another slot."
  fi
fi

# =============================================================================
# STEP 13 -- Spot-Check FIO Commands
# =============================================================================
hdr 13 "Spot-Check -- Per-Drive FIO Baseline Commands"

reason "The guide requires benchmarking each individual drive before testing the"
reason "full topology: 'run a benchmark on each drive (spot check) to verify each"
reason "drive is performing near vendor specs.' One slow or degraded drive will"
reason "silently limit the entire topology -- HBA mode exposes each drive"
reason "independently so catching stragglers before the group test is essential."

if confirm_step; then
  if ! command -v fio &>/dev/null; then
    info "fio not found -- installing..."
    run "dnf install -y fio"
  fi

  echo ""
  echo -e "${BLD}  -- Spot-check FIO commands (run one drive at a time): --${RST}"
  echo ""
  for dev in "${DRIVES[@]}"; do
    echo -e "  ${GRN}# ${dev}  --  4KB Random Read (IOPS check)${RST}"
    echo    "  fio --name=spot_rnd_${dev##*/} --filename=${dev} --ioengine=libaio \\"
    echo    "      --direct=1 --rw=randread --bs=4k --iodepth=32 --numjobs=1 \\"
    echo    "      --runtime=30 --time_based --ramp_time=15 --group_reporting"
    echo ""
    echo -e "  ${GRN}# ${dev}  --  128KB Sequential Read (Throughput check)${RST}"
    echo    "  fio --name=spot_seq_${dev##*/} --filename=${dev} --ioengine=libaio \\"
    echo    "      --direct=1 --rw=read --bs=128k --iodepth=16 --numjobs=1 \\"
    echo    "      --runtime=30 --time_based --ramp_time=15 --group_reporting"
    echo ""
  done
fi

# =============================================================================
# FINAL SUMMARY
# =============================================================================
echo ""
echo -e "${BLD}${CYN}+-------------------------------------------------------------+${RST}"
echo -e "${BLD}${CYN}|  Final Summary Report                                       |${RST}"
echo -e "${BLD}${CYN}+-------------------------------------------------------------+${RST}"
echo ""

if ! $DRY; then
  printf "  ${BLD}%-18s %-10s %-6s %-8s %-8s %-8s${RST}\n" \
    "Drive" "Scheduler" "WCE" "nr_req" "rq_aff" "rd_ahead"
  printf "  %-18s %-10s %-6s %-8s %-8s %-8s\n" \
    "------------------" "---------" "-----" "-------" "-------" "-------"

  for dev in "${DRIVES[@]}"; do
    DEV=$(basename "$dev")
    B="/sys/block/${DEV}/queue"
    SCHED=$(cat "$B/scheduler"      2>/dev/null | grep -oP '\[\K[^\]]+' || echo "?")
    NRQ=$(  cat "$B/nr_requests"    2>/dev/null || echo "?")
    RQA=$(  cat "$B/rq_affinity"    2>/dev/null || echo "?")
    RAK=$(  cat "$B/read_ahead_kb"  2>/dev/null || echo "?")
    WCE_V=$(sdparm -g WCE "$dev"   2>/dev/null | awk '{print $NF}' || echo "?")
    printf "  %-18s %-10s %-6s %-8s %-8s %-8s\n" \
      "$dev" "$SCHED" "$WCE_V" "$NRQ" "$RQA" "${RAK}KB"
  done

  echo ""
  GOV=$( cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "?")
  SWAP=$(sysctl -n vm.swappiness 2>/dev/null || echo "?")
  IRQB=$(systemctl is-active irqbalance 2>/dev/null || echo "?")
  MQ=$(  cat /sys/module/scsi_mod/parameters/use_blk_mq 2>/dev/null || echo "?")
  DR=$(  sysctl -n vm.dirty_ratio 2>/dev/null || echo "?")

  echo -e "  CPU Governor        : ${BLD}$GOV${RST}"
  echo -e "  vm.swappiness       : ${BLD}$SWAP${RST}"
  echo -e "  vm.dirty_ratio      : ${BLD}$DR${RST}"
  echo -e "  irqbalance          : ${BLD}$IRQB${RST}"
  echo -e "  SCSI Block MQ       : ${BLD}$MQ${RST}"
  echo -e "  Workload mode       : ${BLD}$( $RANDOM_MODE && echo 'RANDOM (nomerges=2, read_ahead_kb=0)' || echo 'SEQUENTIAL (nomerges=0, read_ahead_kb=128)' )${RST}"
fi

echo ""
echo -e "${GRN}${BLD}  Tuning complete.  Log: $LOG${RST}"
echo ""
echo -e "${YEL}${BLD}  Before starting your benchmark:${RST}"
echo -e "  1. Run spot-check FIO per drive (Step 13 commands above)."
echo -e "  2. Precondition SSDs if not brand-new -- 2x full sequential write pass."
echo -e "  3. Ramp time >= 30 s, runtime >= 30 s. Run 3x until results within +/-3%."
echo -e "  4. Working set >= 2x host RAM to prevent OS cache from inflating results."
echo -e "  5. To switch workload mode, re-run this script (it will ask again)."
echo -e "  6. To revert all settings:  ${BLD}sudo bash $0 --revert${RST}"
echo ""
