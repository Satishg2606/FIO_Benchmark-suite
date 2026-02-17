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
DO_PRECONDITION=true
DRY_RUN=false

# Test parameter arrays
NUMJOBS_ARRAY=(64)
IODEPTH_ARRAY=(128 256)

# Preconditioning parameters
PRECOND_NUMJOBS=4
PRECOND_IODEPTH=16

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
    if [ "$rotational" == "0" ]; then
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

    local idx=1

    for disk in $(lsblk -nd -o NAME | grep -E '^sd|^nvme'); do
        if [ "$disk" == "$OS_DISK" ]; then
            continue
        fi

        local size=$(lsblk -nd -o SIZE /dev/${disk})
        local model=$(lsblk -nd -o MODEL /dev/${disk} | xargs)
        local type=$(get_disk_type $disk)

        DISKS[$idx]="${disk}|${type}|${size}|${model}"

        if [ "$type" == "HDD" ]; then
            HDD_LIST+=($idx)
        elif [ "$type" == "SSD" ]; then
            SSD_LIST+=($idx)
        fi

        printf "${GREEN}[%2d]${NC} %-10s ${BLUE}%-6s${NC} %-10s %s\n" $idx "/dev/${disk}" "$type" "$size" "$model"
        ((idx++))
    done

    echo ""
}

select_disks() {
    echo -e "${YELLOW}Select disks for testing:${NC}"
    echo -e "${GREEN}[A]${NC}  All HDDs (${#HDD_LIST[@]} disks)"
    echo -e "${GREEN}[S]${NC}  All SSDs (${#SSD_LIST[@]} disks)"
    echo -e "${GREEN}[C]${NC}  Custom selection"
    echo ""
    read -p "Your choice: " disk_choice

    declare -g -a SELECTED_DISKS

    case $disk_choice in
        A|a)
            SELECTED_DISKS=("${HDD_LIST[@]}")
            echo -e "${GREEN}Selected all HDDs${NC}"
            ;;
        S|s)
            SELECTED_DISKS=("${SSD_LIST[@]}")
            echo -e "${GREEN}Selected all SSDs${NC}"
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
        SELECTED_TESTS=("seqread" "seqwrite" "randread" "randwrite" "randrw")
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

    if [ "$DO_PRECONDITION" = false ]; then
        echo -e "${YELLOW}Skipping preconditioning (as per user choice)${NC}"
        return
    fi

    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
    echo -e "${BLUE}PARALLEL PRECONDITIONING${NC}"
    echo -e "${BLUE}Type: ${rw_type} | Block Size: ${bs} | Category: ${test_category}${NC}"
    echo -e "${BLUE}NumJobs: ${PRECOND_NUMJOBS} | IODepth: ${PRECOND_IODEPTH} | Passes: ${PRECOND_PASSES}${NC}"
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
iodepth=${PRECOND_IODEPTH}
numjobs=${PRECOND_NUMJOBS}
group_reporting=1
loops=${PRECOND_PASSES}
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
    case $test in
        seqread)  rw_type="read" ;;
        seqwrite) rw_type="write" ;;
        randread) rw_type="randread" ;;
        randwrite) rw_type="randwrite" ;;
        randrw)   rw_type="randrw" ;;
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
runtime=120
ramp_time=30

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
run_comprehensive_test_suite() {
    declare -a SEQ_TESTS
    declare -a RAND_TESTS

    for test in "${SELECTED_TESTS[@]}"; do
        case $test in
            seqread|seqwrite)        SEQ_TESTS+=("$test") ;;
            randread|randwrite|randrw) RAND_TESTS+=("$test") ;;
        esac
    done

    for bs in "${SELECTED_BLOCK_SIZES[@]}"; do
        echo ""
        echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║      TESTING WITH BLOCK SIZE: ${bs}              ${NC}"
        echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"

        # ── Sequential Tests ──
        if [ ${#SEQ_TESTS[@]} -gt 0 ]; then

            if [ "$RUN_SEQUENTIAL" = true ]; then
                echo ""
                echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}Sequential Mode — Sequential Tests (${bs})${NC}"
                echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"

                for test in "${SEQ_TESTS[@]}"; do
                    echo ""
                    echo -e "${CYAN}Test: ${test} | Block Size: ${bs}${NC}"
                    precondition_disks_parallel "${bs}" "sequential" "seq"

                    for numjobs in "${NUMJOBS_ARRAY[@]}"; do
                        for iodepth in "${IODEPTH_ARRAY[@]}"; do
                            echo -e "${YELLOW}  Configuration: numjobs=${numjobs}, iodepth=${iodepth}${NC}"
                            for idx in "${SELECTED_DISKS[@]}"; do
                                local disk_info="${DISKS[$idx]}"
                                IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
                                local disk="/dev/${disk_name}"
                                echo -e "${BLUE}    → ${disk}${NC}"
                                case $test in
                                    seqread)  run_fio_test_single "$disk" "seqread" "read" "${bs}" "$numjobs" "$iodepth" ;;
                                    seqwrite) run_fio_test_single "$disk" "seqwrite" "write" "${bs}" "$numjobs" "$iodepth" ;;
                                esac
                            done
                        done
                    done
                done
            fi

            if [ "$RUN_PARALLEL" = true ]; then
                echo ""
                echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}Parallel Mode — Sequential Tests (${bs})${NC}"
                echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"

                for test in "${SEQ_TESTS[@]}"; do
                    echo ""
                    echo -e "${CYAN}Test: ${test} | Block Size: ${bs}${NC}"
                    precondition_disks_parallel "${bs}" "sequential" "seq"

                    for numjobs in "${NUMJOBS_ARRAY[@]}"; do
                        for iodepth in "${IODEPTH_ARRAY[@]}"; do
                            run_tests_parallel "${bs}" "$test" "$numjobs" "$iodepth"
                        done
                    done
                done
            fi

            if [ "$RUN_STRESS" = true ]; then
                for test in "${SEQ_TESTS[@]}"; do
                    run_stress_test "${bs}" "$test" "sequential"
                done
            fi
        fi

        # ── Random Tests ──
        if [ ${#RAND_TESTS[@]} -gt 0 ]; then

            if [ "$RUN_SEQUENTIAL" = true ]; then
                echo ""
                echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}Sequential Mode — Random Tests (${bs})${NC}"
                echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"

                for test in "${RAND_TESTS[@]}"; do
                    echo ""
                    echo -e "${CYAN}Test: ${test} | Block Size: ${bs}${NC}"
                    precondition_disks_parallel "${bs}" "random" "rand"

                    for numjobs in "${NUMJOBS_ARRAY[@]}"; do
                        for iodepth in "${IODEPTH_ARRAY[@]}"; do
                            echo -e "${YELLOW}  Configuration: numjobs=${numjobs}, iodepth=${iodepth}${NC}"
                            for idx in "${SELECTED_DISKS[@]}"; do
                                local disk_info="${DISKS[$idx]}"
                                IFS='|' read -r disk_name disk_type disk_size disk_model <<< "$disk_info"
                                local disk="/dev/${disk_name}"
                                echo -e "${BLUE}    → ${disk}${NC}"
                                case $test in
                                    randread)  run_fio_test_single "$disk" "randread" "randread" "${bs}" "$numjobs" "$iodepth" ;;
                                    randwrite) run_fio_test_single "$disk" "randwrite" "randwrite" "${bs}" "$numjobs" "$iodepth" ;;
                                    randrw)    run_fio_test_single "$disk" "randrw" "randrw" "${bs}" "$numjobs" "$iodepth" ;;
                                esac
                            done
                        done
                    done
                done
            fi

            if [ "$RUN_PARALLEL" = true ]; then
                echo ""
                echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
                echo -e "${YELLOW}Parallel Mode — Random Tests (${bs})${NC}"
                echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"

                for test in "${RAND_TESTS[@]}"; do
                    echo ""
                    echo -e "${CYAN}Test: ${test} | Block Size: ${bs}${NC}"
                    precondition_disks_parallel "${bs}" "random" "rand"

                    for numjobs in "${NUMJOBS_ARRAY[@]}"; do
                        for iodepth in "${IODEPTH_ARRAY[@]}"; do
                            run_tests_parallel "${bs}" "$test" "$numjobs" "$iodepth"
                        done
                    done
                done
            fi

            if [ "$RUN_STRESS" = true ]; then
                for test in "${RAND_TESTS[@]}"; do
                    run_stress_test "${bs}" "$test" "random"
                done
            fi
        fi
    done
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

    select_block_sizes
    select_tests
    if [ ${#SELECTED_TESTS[@]} -eq 0 ]; then
        echo -e "${RED}No tests selected${NC}"
        exit 1
    fi

    ask_precondition
    ask_execution_mode

    # ── Configuration summary ──
    echo ""
    echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
    echo -e "${YELLOW}BENCHMARK CONFIGURATION SUMMARY${NC}"
    echo -e "${YELLOW}═══════════════════════════════════════════════${NC}"
    echo -e "Disks: ${GREEN}${#SELECTED_DISKS[@]}${NC}"
    echo -e "Block Sizes: ${GREEN}${SELECTED_BLOCK_SIZES[*]}${NC}"
    echo -e "Tests: ${GREEN}${SELECTED_TESTS[*]}${NC}"
    echo -e "Latency Percentiles: ${GREEN}${PERCENTILE_LIST}${NC}"
    echo -e "Preconditioning: ${GREEN}$([ "$DO_PRECONDITION" = true ] && echo "Enabled (nj=${PRECOND_NUMJOBS}, io=${PRECOND_IODEPTH})" || echo "Disabled")${NC}"
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
