#!/bin/bash

###############################################################################
#  FIO Benchmark Engine — Part of the FIO Benchmark Suite
#  Refactored from fio_benchmark-2.sh with latency percentile support
#  and optional --output-dir override.
###############################################################################

# ─── Colors ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# ─── Defaults ───────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(dirname "$SCRIPT_DIR")"
DEFAULT_DATA_DIR="${SUITE_ROOT}/data/res-logs"

RESULTS_DIR=""
LOG_DIR=""
PRECOND_PASSES=1
RUN_SEQUENTIAL=false
RUN_PARALLEL=false
RUN_STRESS=false
RUN_STRESS=false
DO_PRECONDITION=true
DO_PURGE=true
DRY_RUN=false

# Test parameter arrays
NUMJOBS_ARRAY=(2 4 8 16 32)
IODEPTH_ARRAY=(4 8 16 32)

# Preconditioning parameters
PRECOND_NUMJOBS=32
PRECOND_IODEPTH=32
PRECOND_128K_NUMJOBS=32
PRECOND_128K_IODEPTH=32
PRECOND_128K_PASSES=2
PRECOND_4K_RAND_HOURS=2
COOLDOWN_MINUTES=5

# Latency percentile list for FIO
PERCENTILE_LIST="50:95:99:99.9"

# ─── Parse CLI arguments ────────────────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir)
                RESULTS_DIR="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                echo "Usage: $(basename "$0") [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --output-dir <path>   Use a specific output directory (default: timestamped)"
                echo "  --dry-run             Validate configuration without running FIO"
                echo "  -h, --help            Show this help"
                exit 0
                ;;
            *)
                echo -e "${RED}Unknown option: $1${NC}"
                exit 1
                ;;
        esac
    done

    # Default: timestamped directory inside data/res-logs/
    if [ -z "$RESULTS_DIR" ]; then
        RESULTS_DIR="${DEFAULT_DATA_DIR}/fio_results_$(date +%Y%m%d_%H%M%S)"
    fi
    LOG_DIR="${RESULTS_DIR}/logs"
}

# ─── Directory setup ────────────────────────────────────────────────────────
setup_dirs() {
    mkdir -p "${LOG_DIR}"
    echo -e "${GREEN}Results will be saved to: ${RESULTS_DIR}${NC}"
}

# ─── Disk detection ─────────────────────────────────────────────────────────
get_os_disk() {
    OS_DISK=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null)
    echo "$OS_DISK"
}

get_disk_type() {
    local disk=$1
    local rotational=$(cat /sys/block/${disk}/queue/rotational 2>/dev/null)
    
    if [[ "$disk" == nvme* ]]; then
        echo "NVMe"
    elif [ "$rotational" == "0" ]; then
        echo "SSD"
    elif [ "$rotational" == "1" ]; then
        echo "HDD"
    else
        echo "UNKNOWN"
    fi
}

get_disk_size_bytes() {
    local disk=$1
    lsblk -bnd -o SIZE "/dev/${disk}" | xargs
}

get_cpu_cores() {
    nproc
}

get_max_queue_depth() {
    local disk=$1
    local queue_depth=$(cat /sys/block/${disk}/queue/nr_requests 2>/dev/null)
    if [ -z "$queue_depth" ]; then
        queue_depth=128
    fi
    echo "$queue_depth"
}

# ─── Stress parameter calculation ───────────────────────────────────────────
calculate_stress_params() {
    local num_disks=$1
    local cpu_cores=$(get_cpu_cores)

    local min_queue_depth=999999
    for idx in "${SELECTED_DISKS[@]}"; do
        local disk_info="${DISKS[$idx]}"
        IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
        local qd=$(get_max_queue_depth "${disk_name}")
        if [ "$qd" -lt "$min_queue_depth" ]; then
            min_queue_depth=$qd
        fi
    done

    local numjobs=$cpu_cores
    if [ $numjobs -gt 32 ]; then
        numjobs=32
    fi

    local iodepth=$min_queue_depth
    if [ $iodepth -gt 256 ]; then
        iodepth=256
    fi

    echo "${numjobs}|${iodepth}"
}

# ─── Disk scanning & selection ──────────────────────────────────────────────
detect_disks() {
    echo -e "${YELLOW}Scanning for available disks...${NC}"
    echo ""

    OS_DISK=$(get_os_disk)

    declare -g -A DISKS
    declare -g -a HDD_LIST
    declare -g -a SSD_LIST
    declare -g -a NVME_LIST

    local idx=1

    for disk in $(lsblk -nd -o NAME | grep -E '^sd|^nvme'); do
        if [ "$disk" == "$OS_DISK" ]; then
            continue
        fi

        local size=$(lsblk -nd -o SIZE /dev/${disk})
        local model=$(lsblk -nd -o MODEL /dev/${disk} | xargs)
        local type=$(get_disk_type $disk)

        DISKS[$idx]="${disk}|${type}|${size}|${model}"

        # Classify based on new get_disk_type output
        if [ "$type" == "HDD" ]; then
            HDD_LIST+=($idx)
            type_color="${BLUE}"
        elif [ "$type" == "SSD" ]; then
            SSD_LIST+=($idx)
            type_color="${GREEN}"
        elif [ "$type" == "NVMe" ]; then
            NVME_LIST+=($idx)
            type_color="${MAGENTA}"
        fi

        printf "${GREEN}[%2d]${NC} %-10s ${type_color}%-6s${NC} %-10s %s\n" $idx "/dev/${disk}" "$type" "$size" "$model"
        ((idx++))
    done

    echo ""
}

select_disks() {
    echo -e "${YELLOW}Select disks for testing:${NC}"
    echo -e "${GREEN}[A]${NC}  All Disks (HDD + SATA SSD + NVMe)"
    echo -e "${GREEN}[H]${NC}  All HDDs (${#HDD_LIST[@]} disks)"
    echo -e "${GREEN}[S]${NC}  All SATA SSDs (${#SSD_LIST[@]} disks)"
    echo -e "${GREEN}[N]${NC}  All NVMe SSDs (${#NVME_LIST[@]} disks)"
    echo -e "${GREEN}[C]${NC}  Custom selection"
    echo ""
    read -p "Your choice: " disk_choice

    declare -g -a SELECTED_DISKS

    case $disk_choice in
        A|a)
            SELECTED_DISKS=("${HDD_LIST[@]}" "${SSD_LIST[@]}" "${NVME_LIST[@]}")
            echo -e "${GREEN}Selected all available disks${NC}"
            ;;
        H|h)
            SELECTED_DISKS=("${HDD_LIST[@]}")
            echo -e "${GREEN}Selected all HDDs${NC}"
            ;;
        S|s)
            SELECTED_DISKS=("${SSD_LIST[@]}")
            echo -e "${GREEN}Selected all SATA SSDs${NC}"
            ;;
        N|n)
            SELECTED_DISKS=("${NVME_LIST[@]}")
            echo -e "${GREEN}Selected all NVMe SSDs${NC}"
            ;;
        C|c)
            echo "Enter disk numbers separated by spaces (e.g., 1 3 5):"
            read -a SELECTED_DISKS
            ;;
        *)
            echo -e "${RED}Invalid choice${NC}"
            exit 1
            ;;
    esac
    echo ""
}

# ─── Block size & test selection ─────────────────────────────────────────────
select_block_sizes() {
    echo -e "${YELLOW}Select block sizes for testing:${NC}"
    echo -e "${GREEN}[1]${NC} 4k"
    echo -e "${GREEN}[2]${NC} 128k"
    echo -e "${GREEN}[B]${NC} Both (4k and 128k)"
    echo ""
    read -p "Your choice [1/2/B]: " bs_choice

    declare -g -a SELECTED_BLOCK_SIZES

    case $bs_choice in
        1)  SELECTED_BLOCK_SIZES=("4k")
            echo -e "${GREEN}Selected block size: 4k${NC}" ;;
        2)  SELECTED_BLOCK_SIZES=("128k")
            echo -e "${GREEN}Selected block size: 128k${NC}" ;;
        B|b) SELECTED_BLOCK_SIZES=("4k" "128k")
            echo -e "${GREEN}Selected block sizes: 4k and 128k${NC}" ;;
        *)  echo -e "${RED}Invalid choice, defaulting to 4k${NC}"
            SELECTED_BLOCK_SIZES=("4k") ;;
    esac
    echo ""
}

select_tests() {
    echo -e "${YELLOW}Select tests to run:${NC}"
    echo -e "${GREEN}[1]${NC} Sequential Read (SR)"
    echo -e "${GREEN}[2]${NC} Sequential Write (SW)"
    echo -e "${GREEN}[3]${NC} Random Read (RR)"
    echo -e "${GREEN}[4]${NC} Random Write (RW)"
    echo -e "${GREEN}[5]${NC} Random Read/Write (RRW)"
    echo -e "${GREEN}[A]${NC} All tests"
    echo ""
    echo "Enter test numbers separated by spaces (e.g., 1 2 3) or 'A' for all:"
    read test_input

    declare -g -a SELECTED_TESTS

    if [[ "$test_input" == "A" ]] || [[ "$test_input" == "a" ]]; then
        SELECTED_TESTS=("randread" "randwrite" "randrw" )
    else
        for num in $test_input; do
            case $num in
                1) SELECTED_TESTS+=("seqread") ;;
                2) SELECTED_TESTS+=("seqwrite") ;;
                3) SELECTED_TESTS+=("randread") ;;
                4) SELECTED_TESTS+=("randwrite") ;;
                5) SELECTED_TESTS+=("randrw") ;;
            esac
        done
    fi

    echo -e "${GREEN}Selected tests: ${SELECTED_TESTS[*]}${NC}"
    echo ""
}

# ─── Preconditioning ────────────────────────────────────────────────────────
ask_purge() {
    echo -e "${YELLOW}Do you want to purge (wipe) the disks before testing?${NC}"
    echo -e "${RED}WARNING: This will DESTROY ALL DATA on the selected disks!${NC}"
    echo -e "${GREEN}[Y]${NC} Yes, purge disks (recommended for clean state)"
    echo -e "${GREEN}[N]${NC} No, skip purge"
    echo ""
    read -p "Your choice [Y/N]: " purge_choice

    case $purge_choice in
        Y|y) DO_PURGE=true
             echo -e "${GREEN}Purge enabled${NC}" ;;
        N|n) DO_PURGE=false
             echo -e "${YELLOW}Purge disabled${NC}" ;;
        *)   echo -e "${RED}Invalid choice, defaulting to NO purge${NC}"
             DO_PURGE=false ;;
    esac
    echo ""
}

ask_precondition() {
    echo -e "${YELLOW}Do you want to precondition the disks before testing?${NC}"
    echo -e "${BLUE}Note: Preconditioning writes the entire disk ${PRECOND_PASSES} times to ensure consistent results${NC}"
    echo -e "${RED}WARNING: This will destroy all data on the selected disks!${NC}"
    echo -e "${GREEN}[Y]${NC} Yes, precondition disks (recommended for accurate results)"
    echo -e "${GREEN}[N]${NC} No, skip preconditioning"
    echo ""
    read -p "Your choice [Y/N]: " precond_choice

    case $precond_choice in
        Y|y) DO_PRECONDITION=true
             echo -e "${GREEN}Preconditioning enabled${NC}" ;;
        N|n) DO_PRECONDITION=false
             echo -e "${YELLOW}Preconditioning disabled${NC}" ;;
        *)   echo -e "${RED}Invalid choice, defaulting to NO preconditioning${NC}"
             DO_PRECONDITION=false ;;
    esac
    echo ""
}

ask_execution_mode() {
    echo -e "${YELLOW}Select test execution mode:${NC}"
    echo -e "${GREEN}[1]${NC} Sequential only (one disk at a time, all numjobs/iodepth combinations)"
    echo -e "${GREEN}[2]${NC} Parallel only (all disks simultaneously, all numjobs/iodepth combinations)"
    echo -e "${GREEN}[3]${NC} Stress Test (maximum load — auto-calculated numjobs/iodepth)"
    echo -e "${GREEN}[4]${NC} All modes (Sequential + Parallel + Stress)"
    echo ""
    read -p "Your choice [1/2/3/4]: " exec_choice

    case $exec_choice in
        1) RUN_SEQUENTIAL=true; RUN_PARALLEL=false; RUN_STRESS=false
           echo -e "${GREEN}Sequential mode selected${NC}" ;;
        2) RUN_SEQUENTIAL=false; RUN_PARALLEL=true; RUN_STRESS=false
           echo -e "${GREEN}Parallel mode selected${NC}" ;;
        3) RUN_SEQUENTIAL=false; RUN_PARALLEL=false; RUN_STRESS=true
           echo -e "${GREEN}Stress Test mode selected${NC}" ;;
        4) RUN_SEQUENTIAL=true; RUN_PARALLEL=true; RUN_STRESS=true
           echo -e "${GREEN}All modes selected${NC}" ;;
        *) echo -e "${RED}Invalid choice, defaulting to Sequential${NC}"
           RUN_SEQUENTIAL=true; RUN_PARALLEL=false; RUN_STRESS=false ;;
    esac
    echo ""
}

# ─── Preconditioning progress monitor ───────────────────────────────────────
monitor_precondition_progress() {
    local precond_file=$1
    local total_disks=${#SELECTED_DISKS[@]}

    (
        sleep 5
        while true; do
            for ((i=0; i<total_disks+2; i++)); do
                echo -ne "\033[1A\033[2K"
            done

            echo -e "${CYAN}Preconditioning Progress:${NC}"
            echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

            local all_done=true
            for idx in "${SELECTED_DISKS[@]}"; do
                local disk_info="${DISKS[$idx]}"
                IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
                local status_file="${LOG_DIR}/precond_${disk_name}_status.tmp"
                local progress=0

                if [ -f "$status_file" ]; then
                    progress=$(cat "$status_file" 2>/dev/null || echo "0")
                fi

                if ! pgrep -f "fio.*${precond_file}" > /dev/null 2>&1; then
                    progress=100
                else
                    all_done=false
                fi

                local bar_length=40
                local filled=$((progress * bar_length / 100))
                local empty=$((bar_length - filled))

                printf "${YELLOW}%-10s${NC} [" "/dev/${disk_name}"
                printf "%${filled}s" | tr ' ' '█'
                printf "%${empty}s" | tr ' ' '░'
                printf "] ${GREEN}%3d%%${NC}\n" "$progress"
            done

            if [ "$all_done" = true ]; then
                break
            fi
            sleep 2
        done
    ) &

    local monitor_pid=$!
    echo "$monitor_pid"
}

# ─── Parallel preconditioning ───────────────────────────────────────────────
precondition_disks_parallel() {
    local bs=$1
    local rw_type=$2
    local test_category=$3
    local passes=${4:-${PRECOND_PASSES}}
    local numjobs=${5:-${PRECOND_NUMJOBS}}
    local iodepth=${6:-${PRECOND_IODEPTH}}

    if [ "$DO_PRECONDITION" = false ]; then
        echo -e "${YELLOW}Skipping preconditioning (as per user choice)${NC}"
        return
    fi

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}PARALLEL PRECONDITIONING${NC}"
    echo -e "${BLUE}Type: ${rw_type} | Block Size: ${bs} | Category: ${test_category}${NC}"
    echo -e "${BLUE}NumJobs: ${numjobs} | IODepth: ${iodepth} | Passes: ${passes}${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"

    local precond_file="/tmp/fio_precond_${rw_type}_${bs}_${test_category}_$$.fio"
    local log_file="${LOG_DIR}/precond_parallel_${rw_type}_${bs}_${test_category}.log"

    local write_type="write"
    if [ "$rw_type" == "random" ]; then
        write_type="randwrite"
    fi

    cat > "$precond_file" <<EOF
[global]
ioengine=libaio
direct=1
bs=${bs}
rw=${write_type}
iodepth=${iodepth}
numjobs=${numjobs}
group_reporting=1
loops=${passes}
time_based=0

EOF

    for idx in "${SELECTED_DISKS[@]}"; do
        local disk_info="${DISKS[$idx]}"
        IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
        local disk="/dev/${disk_name}"
        local disk_size_bytes=$(get_disk_size_bytes "${disk_name}")

        cat >> "$precond_file" <<EOF
[precond_${disk_name}]
filename=${disk}
size=${disk_size_bytes}

EOF
    done

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would run preconditioning with:${NC}"
        cat "$precond_file"
        rm -f "$precond_file"
        return
    fi

    echo ""
    echo -e "${CYAN}Starting parallel preconditioning of ${#SELECTED_DISKS[@]} disks...${NC}"
    echo ""

    echo -e "${CYAN}Preconditioning Progress:${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    for idx in "${SELECTED_DISKS[@]}"; do
        local disk_info="${DISKS[$idx]}"
        IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
        printf "${YELLOW}%-10s${NC} [%-40s] ${GREEN}%3d%%${NC}\n" "/dev/${disk_name}" "" 0
    done

    local monitor_pid=$(monitor_precondition_progress "$precond_file")

    fio "$precond_file" > "$log_file" 2>&1

    kill $monitor_pid 2>/dev/null
    wait $monitor_pid 2>/dev/null

    for ((i=0; i<${#SELECTED_DISKS[@]}+2; i++)); do
        echo -ne "\033[1A\033[2K"
    done

    echo -e "${GREEN}✓ Parallel preconditioning complete for all disks${NC}"
    rm -f "$precond_file"
}

# ─── Time-based preconditioning (for 4k random) ─────────────────────────────
precondition_disks_timed() {
    local bs=$1
    local rw_type=$2
    local test_category=$3
    local duration_hours=${4:-2}
    local numjobs=${5:-${PRECOND_NUMJOBS}}
    local iodepth=${6:-${PRECOND_IODEPTH}}

    if [ "$DO_PRECONDITION" = false ]; then
        echo -e "${YELLOW}Skipping preconditioning (as per user choice)${NC}"
        return
    fi

    local runtime_secs=$((duration_hours * 3600))

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}TIME-BASED PARALLEL PRECONDITIONING${NC}"
    echo -e "${BLUE}Type: ${rw_type} | Block Size: ${bs} | Category: ${test_category}${NC}"
    echo -e "${BLUE}NumJobs: ${numjobs} | IODepth: ${iodepth} | Duration: ${duration_hours} hours${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"

    local precond_file="/tmp/fio_precond_${rw_type}_${bs}_${test_category}_$$.fio"
    local log_file="${LOG_DIR}/precond_timed_${rw_type}_${bs}_${test_category}.log"

    local write_type="write"
    if [ "$rw_type" == "random" ]; then
        write_type="randwrite"
    fi

    cat > "$precond_file" <<EOF
[global]
ioengine=libaio
direct=1
bs=${bs}
rw=${write_type}
iodepth=${iodepth}
numjobs=${numjobs}
group_reporting=1
time_based=1
runtime=${runtime_secs}

EOF

    for idx in "${SELECTED_DISKS[@]}"; do
        local disk_info="${DISKS[$idx]}"
        IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
        local disk="/dev/${disk_name}"

        cat >> "$precond_file" <<EOF
[precond_${disk_name}]
filename=${disk}

EOF
    done

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would run time-based preconditioning with:${NC}"
        cat "$precond_file"
        rm -f "$precond_file"
        return
    fi

    echo ""
    echo -e "${CYAN}Starting ${duration_hours}-hour preconditioning of ${#SELECTED_DISKS[@]} disks...${NC}"
    echo -e "${CYAN}Estimated completion: $(date -d "+${duration_hours} hours" '+%Y-%m-%d %H:%M:%S')${NC}"
    echo ""

    fio "$precond_file" > "$log_file" 2>&1

    echo -e "${GREEN}✓ Time-based preconditioning complete for all disks${NC}"
    rm -f "$precond_file"
}

# ─── Purge/Format disks ─────────────────────────────────────────────────────
purge_disks() {
    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  STEP 1: PURGE / FORMAT DISKS                  ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════╝${NC}"
    if [ "$DO_PURGE" = false ]; then
        echo -e "${YELLOW}Skipping purge (as per user choice)${NC}"
        return
    fi

    echo -e "${CYAN}Purging ${#SELECTED_DISKS[@]} disks to factory-clean state...${NC}"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would purge all selected disks${NC}"
        return
    fi

    local pids=()
    for idx in "${SELECTED_DISKS[@]}"; do
        local disk_info="${DISKS[$idx]}"
        IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
        local disk="/dev/${disk_name}"

        if command -v blkdiscard &> /dev/null; then
            echo -e "${BLUE}  Purging ${disk} (blkdiscard)...${NC}"
            blkdiscard "$disk" 2>/dev/null &
            pids+=($!)
        else
            echo -e "${BLUE}  Purging ${disk} (dd zero-fill)...${NC}"
            dd if=/dev/zero of="$disk" bs=1M status=none 2>/dev/null &
            pids+=($!)
        fi
    done

    # Wait for all purge operations to complete
    for pid in "${pids[@]}"; do
        wait $pid 2>/dev/null
    done

    echo -e "${GREEN}✓ All disks purged successfully${NC}"
}

# ─── Cooldown ────────────────────────────────────────────────────────────────
cooldown() {
    local minutes=${1:-${COOLDOWN_MINUTES}}
    local total_secs=$((minutes * 60))

    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  COOLDOWN — ${minutes} MINUTES IDLE                     ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════╝${NC}"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Would idle for ${minutes} minutes${NC}"
        return
    fi

    for ((remaining=total_secs; remaining>0; remaining--)); do
        local mins=$((remaining / 60))
        local secs=$((remaining % 60))
        printf "\r${CYAN}  Cooling down: %02d:%02d remaining...${NC}" $mins $secs
        sleep 1
    done
    printf "\r${GREEN}  Cooldown complete!                          ${NC}\n"
}

# ─── Single-disk FIO test ───────────────────────────────────────────────────
run_fio_test_single() {
    local disk=$1
    local test_name=$2
    local rw=$3
    local bs=$4
    local numjobs=$5
    local iodepth=$6

    local output_file="${RESULTS_DIR}/${disk##*/}_${test_name}_${bs}_nj${numjobs}_io${iodepth}_$(date +%H%M%S).log"

    echo -e "${BLUE}    nj=${numjobs} io=${iodepth}${NC}"

    # Set rwmixread for randrw tests (70:30 read:write ratio)
    local rwmixread_param=""
    if [ "$rw" == "randrw" ]; then
        rwmixread_param="rwmixread=70"
    fi

    local job_file="/tmp/fio_job_$$.fio"
    cat > "$job_file" <<EOF
[global]
ioengine=libaio
direct=1
time_based=1
randrepeat=0
norandommap
gtod_reduce=0
prio=0
bwavgtime=1000
iopsavgtime=1000
disable_lat=0
disable_clat=0
disable_slat=0
clat_percentiles=1
percentile_list=${PERCENTILE_LIST}
numa_cpu_nodes=0
blockalign=4k
group_reporting=1
rw=${rw}
blocksize=${bs}
numjobs=${numjobs}
iodepth=${iodepth}
runtime=60
ramp_time=15
${rwmixread_param}

[${test_name}]
stonewall
description=${test_name}_${disk##*/}_${bs}_nj${numjobs}_io${iodepth}
filename=${disk}
EOF

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Job file for ${disk} (${test_name}):${NC}"
        cat "$job_file"
        rm -f "$job_file"
        return
    fi

    fio "$job_file" --output="${output_file}" 2>&1 | grep -E "READ:|WRITE:|bw=|lat|percentile" || true

    rm -f "$job_file"
}

# ─── Parallel FIO test ──────────────────────────────────────────────────────
run_tests_parallel() {
    local bs=$1
    local test=$2
    local numjobs=$3
    local iodepth=$4

    echo -e "${BLUE}  nj=${numjobs} io=${iodepth} - Running on all disks in parallel...${NC}"

    local output_file="${RESULTS_DIR}/parallel_${test}_${bs}_nj${numjobs}_io${iodepth}_$(date +%H%M%S).log"

    local rw_type=""
    local rwmixread=""
    case $test in
        randread) rw_type="randread" ;;
        randwrite) rw_type="randwrite" ;;
        randrw)   rw_type="randrw"; rwmixread="70" ;;
    esac

    local job_file="/tmp/fio_parallel_$$.fio"
    cat > "$job_file" <<EOF
[global]
ioengine=libaio
direct=1
time_based=1
randrepeat=0
norandommap
gtod_reduce=0
prio=0
bwavgtime=1000
iopsavgtime=1000
disable_lat=0
disable_clat=0
disable_slat=0
clat_percentiles=1
percentile_list=${PERCENTILE_LIST}
numa_cpu_nodes=0
blockalign=4k
group_reporting=1
rw=${rw_type}
blocksize=${bs}
numjobs=${numjobs}
iodepth=${iodepth}
runtime=60
ramp_time=15
EOF

    # Add rwmixread if this is randrw test
    if [ -n "$rwmixread" ]; then
        echo "rwmixread=${rwmixread}" >> "$job_file"
    fi

    cat >> "$job_file" <<EOF

EOF

    for idx in "${SELECTED_DISKS[@]}"; do
        local disk_info="${DISKS[$idx]}"
        IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
        local disk="/dev/${disk_name}"

        cat >> "$job_file" <<EOF
[${disk_name}_${test}_${bs}]
rw=${rw_type}
blocksize=${bs}
filename=${disk}
group_reporting=1
new_group=1

EOF
    done

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Parallel job file:${NC}"
        cat "$job_file"
        rm -f "$job_file"
        return
    fi

    fio "$job_file" --output="${output_file}" 2>&1 | grep -E "READ:|WRITE:|bw=|lat|percentile" || true

    rm -f "$job_file"
}

# ─── Stress test ─────────────────────────────────────────────────────────────
run_stress_test() {
    local bs=$1
    local test=$2
    local rw_type=$3

    local stress_params=$(calculate_stress_params ${#SELECTED_DISKS[@]})
    IFS='|' read -r numjobs iodepth <<< "$stress_params"

    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║           STRESS TEST MODE                     ║${NC}"
    echo -e "${MAGENTA}║  Auto-calculated for maximum load              ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════╝${NC}"
    echo -e "${CYAN}System CPU Cores: ${GREEN}$(get_cpu_cores)${NC}"
    echo -e "${CYAN}Calculated NumJobs: ${GREEN}${numjobs}${NC}"
    echo -e "${CYAN}Calculated IODepth: ${GREEN}${iodepth}${NC}"
    echo -e "${CYAN}Block Size: ${GREEN}${bs}${NC}"
    echo -e "${CYAN}Test: ${GREEN}${test}${NC}"
    echo ""

    precondition_disks_parallel "${bs}" "${rw_type}" "stress"

    echo -e "${MAGENTA}Running stress test on all ${#SELECTED_DISKS[@]} disks...${NC}"

    local output_file="${RESULTS_DIR}/stress_${test}_${bs}_nj${numjobs}_io${iodepth}_$(date +%H%M%S).log"

    local fio_rw=""
    case $test in
        seqread)  fio_rw="read" ;;
        seqwrite) fio_rw="write" ;;
        randread) fio_rw="randread" ;;
        randwrite) fio_rw="randwrite" ;;
        randrw)   fio_rw="randrw" ;;
    esac

    local job_file="/tmp/fio_stress_$$.fio"
    cat > "$job_file" <<EOF
[global]
ioengine=libaio
direct=1
time_based=1
randrepeat=0
norandommap
gtod_reduce=0
bwavgtime=1000
iopsavgtime=1000
clat_percentiles=1
percentile_list=${PERCENTILE_LIST}
blockalign=4k
numjobs=${numjobs}
iodepth=${iodepth}
runtime=60
ramp_time=15

EOF

    for idx in "${SELECTED_DISKS[@]}"; do
        local disk_info="${DISKS[$idx]}"
        IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
        local disk="/dev/${disk_name}"

        cat >> "$job_file" <<EOF
[${disk_name}_stress_${test}]
rw=${fio_rw}
blocksize=${bs}
filename=${disk}
group_reporting=1
new_group=1

EOF
    done

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}[DRY-RUN] Stress job file:${NC}"
        cat "$job_file"
        rm -f "$job_file"
        return
    fi

    fio "$job_file" --output="${output_file}" 2>&1 | tail -20

    echo -e "${GREEN}✓ Stress test complete${NC}"
    echo -e "${YELLOW}Results: ${output_file}${NC}"

    rm -f "$job_file"
}

# ─── Comprehensive test suite runner ────────────────────────────────────────
# Fixed 6-step linear flow:
#   1. Purge/Format
#   2. Sequential Precondition (128k, 2 passes)
#   3. Sequential Benchmarks (128k: Read → Write)
#   4. Cooldown (5 minutes)
#   5. Random Precondition (4k, 2 hours time-based)
#   6. Random Benchmarks (4k: Read → Write → RW 70:30)
# ────────────────────────────────────────────────────────────────────────────
run_comprehensive_test_suite() {

    # ══════════════════════════════════════════════════════════════════════
    # STEP 1: Purge / Format
    # ══════════════════════════════════════════════════════════════════════
    purge_disks

    # ══════════════════════════════════════════════════════════════════════
    # STEP 2: Sequential Preconditioning (128k, 2 passes)
    # ══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  STEP 2: SEQUENTIAL PRECONDITIONING (128k)     ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════╝${NC}"
    precondition_disks_parallel "128k" "sequential" "seq" "${PRECOND_128K_PASSES}" "${PRECOND_128K_NUMJOBS}" "${PRECOND_128K_IODEPTH}"

    # ══════════════════════════════════════════════════════════════════════
    # STEP 3: Sequential Benchmarks (128k: seqread → seqwrite)
    # ══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  STEP 3: SEQUENTIAL BENCHMARKS (128k)          ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"

    local SEQ_TESTS=("seqwrite" "seqread")

    if [ "$RUN_SEQUENTIAL" = true ]; then
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}Sequential Mode — 128k Tests${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"

        for test in "${SEQ_TESTS[@]}"; do
            echo ""
            echo -e "${CYAN}Test: ${test} | Block Size: 128k${NC}"

            for numjobs in "${NUMJOBS_ARRAY[@]}"; do
                for iodepth in "${IODEPTH_ARRAY[@]}"; do
                    echo -e "${YELLOW}  Configuration: numjobs=${numjobs}, iodepth=${iodepth}${NC}"
                    for idx in "${SELECTED_DISKS[@]}"; do
                        local disk_info="${DISKS[$idx]}"
                        IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
                        local disk="/dev/${disk_name}"
                        echo -e "${BLUE}    → ${disk}${NC}"
                        case $test in
                            seqread)  run_fio_test_single "$disk" "seqread" "read" "128k" "$numjobs" "$iodepth" ;;
                            seqwrite) run_fio_test_single "$disk" "seqwrite" "write" "128k" "$numjobs" "$iodepth" ;;
                        esac
                    done
                done
            done
        done
    fi

    if [ "$RUN_PARALLEL" = true ]; then
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}Parallel Mode — 128k Tests${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"

        for test in "${SEQ_TESTS[@]}"; do
            echo ""
            echo -e "${CYAN}Test: ${test} | Block Size: 128k${NC}"

            for numjobs in "${NUMJOBS_ARRAY[@]}"; do
                for iodepth in "${IODEPTH_ARRAY[@]}"; do
                    run_tests_parallel "128k" "$test" "$numjobs" "$iodepth"
                done
            done
        done
    fi

    if [ "$RUN_STRESS" = true ]; then
        for test in "${SEQ_TESTS[@]}"; do
            run_stress_test "128k" "$test" "sequential"
        done
    fi

    # ══════════════════════════════════════════════════════════════════════
    # STEP 4: Cooldown (5 minutes)
    # ══════════════════════════════════════════════════════════════════════

    # ══════════════════════════════════════════════════════════════════════
    # STEP 5: Random Preconditioning (4k, 2 hours time-based)
    # ══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${MAGENTA}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${MAGENTA}║  STEP 5: RANDOM PRECONDITIONING (4k, 2 hrs)   ║${NC}"
    echo -e "${MAGENTA}╚════════════════════════════════════════════════╝${NC}"
    precondition_disks_timed "4k" "random" "rand" "${PRECOND_4K_RAND_HOURS}" "${PRECOND_NUMJOBS}" "${PRECOND_IODEPTH}"

    # ══════════════════════════════════════════════════════════════════════
    # STEP 6: Random Benchmarks (4k: randread → randwrite → randrw)
    # ══════════════════════════════════════════════════════════════════════
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  STEP 6: RANDOM BENCHMARKS (4k)                ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"

    local RAND_TESTS=("randwrite" "randread" "randrw")

    if [ "$RUN_SEQUENTIAL" = true ]; then
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}Sequential Mode — 4k Random Tests${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"

        for test in "${RAND_TESTS[@]}"; do
            echo ""
            echo -e "${CYAN}Test: ${test} | Block Size: 4k${NC}"

            for numjobs in "${NUMJOBS_ARRAY[@]}"; do
                for iodepth in "${IODEPTH_ARRAY[@]}"; do
                    echo -e "${YELLOW}  Configuration: numjobs=${numjobs}, iodepth=${iodepth}${NC}"
                    for idx in "${SELECTED_DISKS[@]}"; do
                        local disk_info="${DISKS[$idx]}"
                        IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
                        local disk="/dev/${disk_name}"
                        echo -e "${BLUE}    → ${disk}${NC}"
                        case $test in
                            randread)  run_fio_test_single "$disk" "randread" "randread" "4k" "$numjobs" "$iodepth" ;;
                            randwrite) run_fio_test_single "$disk" "randwrite" "randwrite" "4k" "$numjobs" "$iodepth" ;;
                            randrw)    run_fio_test_single "$disk" "randrw" "randrw" "4k" "$numjobs" "$iodepth" ;;
                        esac
                    done
                done
            done
        done
    fi

    if [ "$RUN_PARALLEL" = true ]; then
        echo ""
        echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
        echo -e "${YELLOW}Parallel Mode — 4k Random Tests${NC}"
        echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"

        for test in "${RAND_TESTS[@]}"; do
            echo ""
            echo -e "${CYAN}Test: ${test} | Block Size: 4k${NC}"

            for numjobs in "${NUMJOBS_ARRAY[@]}"; do
                for iodepth in "${IODEPTH_ARRAY[@]}"; do
                    run_tests_parallel "4k" "$test" "$numjobs" "$iodepth"
                done
            done
        done
    fi

    if [ "$RUN_STRESS" = true ]; then
        for test in "${RAND_TESTS[@]}"; do
            run_stress_test "4k" "$test" "random"
        done
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────
main() {
    parse_args "$@"

    echo -e "${BLUE}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       FIO Benchmark Suite — Engine             ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════╝${NC}"
    echo ""

    # Check root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root${NC}"
        exit 1
    fi

    # Check fio
    if ! command -v fio &> /dev/null; then
        echo -e "${RED}FIO is not installed. Please install it first.${NC}"
        exit 1
    fi

    setup_dirs
    detect_disks

    if [ ${#DISKS[@]} -eq 0 ]; then
        echo -e "${RED}No suitable disks found for testing${NC}"
        exit 1
    fi

    select_disks
    if [ ${#SELECTED_DISKS[@]} -eq 0 ]; then
        echo -e "${RED}No disks selected${NC}"
        exit 1
    fi

    # Block sizes and tests are fixed:
    # 128k: seqread, seqwrite
    # 4k: randread, randwrite, randrw (70:30)
    echo -e "${CYAN}Fixed test plan:${NC}"
    echo -e "${CYAN}  Step 1: Purge disks${NC}"
    echo -e "${CYAN}  Step 2: Precondition 128k sequential (2 passes, 32NJ/32IO)${NC}"
    echo -e "${CYAN}  Step 3: 128k Sequential Write → Sequential Read${NC}"
    echo -e "${CYAN}  Step 4: Cooldown (${COOLDOWN_MINUTES} minutes)${NC}"
    echo -e "${CYAN}  Step 5: Precondition 4k random (${PRECOND_4K_RAND_HOURS} hours, 32NJ/32IO)${NC}"
    echo -e "${CYAN}  Step 6: 4k Random Write → Random Read → Random RW (70:30)${NC}"
    echo ""

    ask_purge
    ask_precondition
    ask_execution_mode

    # ── Configuration summary ──
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}BENCHMARK CONFIGURATION SUMMARY${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
    echo -e "Disks: ${GREEN}${#SELECTED_DISKS[@]}${NC}"
    echo -e "Test Flow:${NC}"
    echo -e "  ${GREEN}1${NC}. Purge/Format all disks"
    echo -e "  ${GREEN}2${NC}. 128k sequential precondition (2 passes, 32NJ/32IO)"
    echo -e "  ${GREEN}3${NC}. 128k benchmarks: Sequential Read, Sequential Write"
    echo -e "  ${GREEN}4${NC}. Cooldown: ${COOLDOWN_MINUTES} minutes"
    echo -e "  ${GREEN}5${NC}. 4k random precondition (${PRECOND_4K_RAND_HOURS} hours, 32NJ/32IO)"
    echo -e "  ${GREEN}6${NC}. 4k benchmarks: Random Read, Random Write, Random RW (70:30)"
    echo -e "Latency Percentiles: ${GREEN}${PERCENTILE_LIST}${NC}"
    echo -e "Purge: ${GREEN}$([ "$DO_PURGE" = true ] && echo "Enabled" || echo "Disabled")${NC}"
    echo -e "Preconditioning: ${GREEN}$([ "$DO_PRECONDITION" = true ] && echo "Enabled" || echo "Disabled")${NC}"
    echo -e "Execution Modes:"
    [ "$RUN_SEQUENTIAL" = true ] && echo -e "  ${GREEN}✓${NC} Sequential (numjobs: ${NUMJOBS_ARRAY[*]} | iodepth: ${IODEPTH_ARRAY[*]})"
    [ "$RUN_PARALLEL" = true ]   && echo -e "  ${GREEN}✓${NC} Parallel (numjobs: ${NUMJOBS_ARRAY[*]} | iodepth: ${IODEPTH_ARRAY[*]})"
    [ "$RUN_STRESS" = true ]     && echo -e "  ${GREEN}✓${NC} Stress Test (auto-calculated)"
    echo -e "Results Directory: ${GREEN}${RESULTS_DIR}${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"

    if [ "$RUN_SEQUENTIAL" = true ] || [ "$RUN_PARALLEL" = true ]; then
        local total_combinations=$((${#NUMJOBS_ARRAY[@]} * ${#IODEPTH_ARRAY[@]}))
        echo -e "${CYAN}Total configurations per test: ${GREEN}${total_combinations}${NC}"
    fi

    if [ "$DRY_RUN" = true ]; then
        echo ""
        echo -e "${YELLOW}═══ DRY-RUN MODE — no FIO commands will be executed ═══${NC}"
        echo ""
    fi

    echo ""
    read -p "Press Enter to start benchmarking..."

    run_comprehensive_test_suite

    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   All tests completed successfully!           ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    echo -e "Results directory: ${BLUE}${RESULTS_DIR}${NC}"
    echo -e "${CYAN}Run the result parser to convert logs to CSV:${NC}"
    echo -e "  python3 ${SUITE_ROOT}/src/result_parser.py --input ${RESULTS_DIR}"
}

main "$@"
