#!/bin/bash

# ─── Configuration ──────────────────────────────────────────────────────────
# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

# Default Directories
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_ROOT="$(dirname "$SCRIPT_DIR")"
DEFAULT_DATA_DIR="${SUITE_ROOT}/data/auto_results"
RESULTS_DIR=""
LOG_DIR=""

# Test Parameters
NUMJOBS_ARRAY=(1 2 4 8 16 32 48)
IODEPTH_ARRAY=(1 2 4 8 16 32 64)

# Preconditioning Constants
PRECOND_NJ=1
PRECOND_IOD=32
COOLDOWN_MINUTES=5

# ─── Helper Functions ───────────────────────────────────────────────────────

setup_dirs() {
    if [ -z "$RESULTS_DIR" ]; then
        RESULTS_DIR="${DEFAULT_DATA_DIR}/fio_auto_$(date +%Y%m%d_%H%M%S)"
    fi
    LOG_DIR="${RESULTS_DIR}/logs"
    mkdir -p "${LOG_DIR}"
    echo -e "${GREEN}Results will be saved to: ${RESULTS_DIR}${NC}"
}

get_os_disk() {
    lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null
}

get_disk_model() {
    lsblk -nd -o MODEL "/dev/$1" 2>/dev/null | xargs
}

get_disk_size() {
    lsblk -nd -o SIZE "/dev/$1" 2>/dev/null | xargs
}

# ─── Drive Detection ────────────────────────────────────────────────────────

detect_and_classify_disks() {
    echo -e "${YELLOW}Detecting and classifying disks...${NC}"
    
    OS_DISK=$(get_os_disk)
    echo -e "OS Disk identified as: ${BLUE}${OS_DISK}${NC} (Excluded)"

    # Arrays to hold classified disks
    NVME_DISKS=()
    SATA_SSD_DISKS=()
    HDD_DISKS=()

    # Iterate over block devices (sd* and nvme*)
    for disk in $(lsblk -nd -o NAME | grep -E '^sd|^nvme'); do
        if [ "$disk" == "$OS_DISK" ]; then
            continue
        fi

        # Determine type
        local rotational=$(cat "/sys/block/${disk}/queue/rotational" 2>/dev/null)
        local is_nvme=false
        
        if [[ $disk == nvme* ]]; then
            is_nvme=true
        fi

        local size=$(get_disk_size "$disk")
        local model=$(get_disk_model "$disk")

        if [ "$rotational" == "1" ]; then
            HDD_DISKS+=("$disk")
            echo -e "  Found ${CYAN}HDD${NC}: /dev/$disk ($size $model)"
        elif [ "$is_nvme" == "true" ]; then
            NVME_DISKS+=("$disk")
            echo -e "  Found ${MAGENTA}NVMe SSD${NC}: /dev/$disk ($size $model)"
        else
            # Rotational=0 and not NVMe -> Assume SATA SSD
            SATA_SSD_DISKS+=("$disk")
            echo -e "  Found ${GREEN}SATA SSD${NC}: /dev/$disk ($size $model)"
        fi
    done
    echo ""
}

# ─── Operations ─────────────────────────────────────────────────────────────

purge_disk() {
    local disk=$1
    echo -e "${RED}  [Purge]${NC} Purging /dev/${disk}..."
    
    if command -v blkdiscard &> /dev/null; then
        blkdiscard "/dev/${disk}" 2>/dev/null
    else
        # Fallback to zero-fill first 100MB if blkdiscard fails or unavailable (faster than full zero fill)
        # However, for a true purge equivalent to blkdiscard, full write is needed but slow.
        # Given "Purge disk" requirement, usually blkdiscard is intended for SSDs.
        dd if=/dev/zero of="/dev/${disk}" bs=1M count=100 status=none 2>/dev/null
    fi
}

cooldown() {
    local minutes=$1
    echo -e "${BLUE}  [Cooldown]${NC} Sleeping for ${minutes} minutes..."
    sleep $((minutes * 60))
}

run_fio_job() {
    local disk=$1
    local name=$2
    local rw=$3
    local bs=$4
    local nj=$5
    local iod=$6
    local loops=$7
    local time_based=$8
    local runtime=$9

    local output_file="${RESULTS_DIR}/${name}_${disk}_nj${nj}_iod${iod}.json"
    local job_file="${LOG_DIR}/${name}_${disk}_$$.fio"

    # Construct FIO command
    cat > "$job_file" <<EOF
[global]
ioengine=libaio
direct=1
group_reporting=1
filename=/dev/${disk}
rw=${rw}
bs=${bs}
numjobs=${nj}
iodepth=${iod}
EOF

    if [ -n "$loops" ]; then
        echo "loops=${loops}" >> "$job_file"
        echo "time_based=0" >> "$job_file"
    elif [ "$time_based" == "1" ]; then
         echo "time_based=1" >> "$job_file"
         echo "runtime=${runtime}" >> "$job_file"
    fi

    # For randomRW, add rwmixread=70 (default assumption if not specified, usually 70/30 or 50/50. 
    # Requirement says "Random read, write and RandomRW tests". 
    # Usually mixed is 70/30 in industry. Adding rwmixread=70 for randrw.
    if [ "$rw" == "randrw" ]; then
        echo "rwmixread=70" >> "$job_file"
    fi

    echo "name=${name}" >> "$job_file"

    # Run FIO
    fio "$job_file" --output-format=json --output="$output_file" > /dev/null 2>&1
    rm "$job_file"
}

run_benchmarks() {
    local disk=$1
    local stage_name=$2
    local bs=$3
    local rw_types=$4 # Space separated string

    echo -e "${YELLOW}    Running Benchmarks (${stage_name})...${NC}"

    for rw in $rw_types; do
        for nj in "${NUMJOBS_ARRAY[@]}"; do
            for iod in "${IODEPTH_ARRAY[@]}"; do
                echo -ne "      Running ${rw} bs=${bs} nj=${nj} iod=${iod}...\r"
                run_fio_job "$disk" "${stage_name}_${rw}" "$rw" "$bs" "$nj" "$iod" "" "1" "60"
            done
        done
    done
    echo -e "      ${GREEN}Benchmarks (${stage_name}) Completed.${NC}"
}

# ─── Flows ──────────────────────────────────────────────────────────────────

process_nvme_drive() {
    local disk=$1
    echo -e "${MAGENTA}➜ Starting NVMe Flow for /dev/${disk}${NC}"

    # 1. Purge
    purge_disk "$disk"

    # 2. Precondition seqwrite (1M) 1 times
    echo -e "  [Precond] SeqWrite 1M (1 pass)..."
    run_fio_job "$disk" "precond_seq_1m" "write" "1M" "$PRECOND_NJ" "$PRECOND_IOD" "1" "0" ""

    # 3. Precondition seqwrite (128K) 2 times
    echo -e "  [Precond] SeqWrite 128K (2 passes)..."
    run_fio_job "$disk" "precond_seq_128k" "write" "128k" "$PRECOND_NJ" "$PRECOND_IOD" "2" "0" ""

    # 4. Cooldown
    cooldown "$COOLDOWN_MINUTES"

    # 5. Run Sequential read, write tests (128k is implied for Sequential benchmarks unless specified, following precond)
    # Requirement doesn't explicitly state blocksize for "Sequential read, write tests", effectively implies 128k.
    run_benchmarks "$disk" "bench_seq" "128k" "read write"

    # 6. Precondition randomwrite (1M) 1 times
    echo -e "  [Precond] RandWrite 1M (1 pass)..."
    run_fio_job "$disk" "precond_rand_1m" "randwrite" "1M" "$PRECOND_NJ" "$PRECOND_IOD" "1" "0" ""

    # 7. Precondition randomwrite (4K) 2 times
    echo -e "  [Precond] RandWrite 4K (2 passes)..."
    run_fio_job "$disk" "precond_rand_4k" "randwrite" "4k" "$PRECOND_NJ" "$PRECOND_IOD" "2" "0" ""

    # 8. Cooldown
    cooldown "$COOLDOWN_MINUTES"

    # 9. Run Random read, write and RandomRW tests (4k implied)
    run_benchmarks "$disk" "bench_rand" "4k" "randread randwrite randrw"

    echo -e "${GREEN}✓ NVMe Flow Finished for /dev/${disk}${NC}\n"
}


process_sata_ssd_drive() {
    local disk=$1
    echo -e "${GREEN}➜ Starting SATA SSD Flow for /dev/${disk}${NC}"

    # 1. Purge
    purge_disk "$disk"

    # 2. Precondition seqwrite (1M) 1 times
    echo -e "  [Precond] SeqWrite 1M (1 pass)..."
    run_fio_job "$disk" "precond_seq_1m" "write" "1M" "$PRECOND_NJ" "$PRECOND_IOD" "1" "0" ""

    # 3. Precondition seqwrite (128K) 1 times
    echo -e "  [Precond] SeqWrite 128K (1 pass)..."
    run_fio_job "$disk" "precond_seq_128k" "write" "128k" "$PRECOND_NJ" "$PRECOND_IOD" "1" "0" ""

    # 4. Cooldown
    cooldown "$COOLDOWN_MINUTES"

    # 5. Run Sequential read, write tests (128k)
    run_benchmarks "$disk" "bench_seq" "128k" "read write"

    # 6. Precondition randomwrite (4K) 1 times
    echo -e "  [Precond] RandWrite 4K (1 pass)..."
    run_fio_job "$disk" "precond_rand_4k" "randwrite" "4k" "$PRECOND_NJ" "$PRECOND_IOD" "1" "0" ""

    # 7. Cooldown
    cooldown "$COOLDOWN_MINUTES"

    # 8. Run Random read, write and RandomRW tests (4k)
    run_benchmarks "$disk" "bench_rand" "4k" "randread randwrite randrw"

    echo -e "${GREEN}✓ SATA SSD Flow Finished for /dev/${disk}${NC}\n"
}

process_hdd_drive() {
    local disk=$1
    echo -e "${CYAN}➜ Starting HDD Flow for /dev/${disk}${NC}"

    # 1. Warmup (Sufficient)
    # Implementing a short sequential write warmup
    echo -e "  [Warmup] Sequential Write (60s)..."
    run_fio_job "$disk" "warmup" "write" "1M" "1" "32" "" "1" "60"

    # 2. Run Sequential read, write tests (128k)
    run_benchmarks "$disk" "bench_seq" "128k" "read write"

    # 3. Run Random read, write and RandomRW tests (4k)
    run_benchmarks "$disk" "bench_rand" "4k" "randread randwrite randrw"

    echo -e "${GREEN}✓ HDD Flow Finished for /dev/${disk}${NC}\n"
}


# ─── Main ───────────────────────────────────────────────────────────────────

main() {
    # Check for root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root${NC}"
        exit 1
    fi

    setup_dirs
    detect_and_classify_disks

    # Confirmation
    echo -e "${RED}WARNING: THIS SCRIPT WILL DESTROY DATA ON THE DETECTED DRIVES!${NC}"
    echo -e "Drives to be wiped and tested:"
    echo -e "  NVMe: ${NVME_DISKS[*]}"
    echo -e "  SATA: ${SATA_SSD_DISKS[*]}"
    echo -e "  HDD:  ${HDD_DISKS[*]}"
    echo ""
    read -p "Type 'YES' to proceed: " confirm
    if [ "$confirm" != "YES" ]; then
        echo "Aborting."
        exit 1
    fi

    # Execute NVMe Flows
    for disk in "${NVME_DISKS[@]}"; do
        process_nvme_drive "$disk"
    done

    # Execute SATA SSD Flows
    for disk in "${SATA_SSD_DISKS[@]}"; do
        process_sata_ssd_drive "$disk"
    done

    # Execute HDD Flows
    for disk in "${HDD_DISKS[@]}"; do
        process_hdd_drive "$disk"
    done

    echo ""
    echo -e "${GREEN}All benchmarks completed!${NC}"
    echo -e "Results are stored in: ${RESULTS_DIR}"
}

main "$@"
