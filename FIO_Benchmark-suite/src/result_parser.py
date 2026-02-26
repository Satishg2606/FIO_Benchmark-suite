#!/usr/bin/env python3
"""
Result Parser — Converts FIO plain-text log files into structured CSV.

Usage:
    python3 result_parser.py --input <results-dir-or-file> [--output <output-dir>]

Parses FIO text output to extract:
    IOPS, Bandwidth, Latency (mean, p50, p95, p99, p99.9)
"""

import argparse
import csv
import os
import re
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List

# ── Add parent to path for config import ────────────────────────────────────
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import PARSED_RESULTS_DIR, RESULT_CSV_COLUMNS


# Matches lines like:  read: IOPS=125k, BW=501MiB/s (525MB/s)(29.4GiB/60002msec)
RE_IOPS_BW = re.compile(
    r"(read|write)\s*:\s*IOPS=([\d.]+[kKmM]?),\s*BW=([\d.]+)(\w+/s)",
    re.IGNORECASE,
)

# Matches lines like:     lat (usec): min=152, max=58420, avg=512.34, stdev=231.10
# We only match "lat" exactly, avoiding clat/slat
RE_LAT_AVG = re.compile(
    r"^\s+lat\s*\((\w+)\)\s*:\s*min=.*avg=\s*([\d.]+)",
    re.MULTILINE | re.IGNORECASE,
)

# Matches the job description to extract disk/test params from the description field
# e.g.  description=randread_sda_4k_nj64_io128
RE_DESCRIPTION = re.compile(
    r"description=(\w+)_([a-zA-Z0-9]+)_(\d+k?)_nj(\d+)_io(\d+)", re.IGNORECASE
)

# Matches filename from output file name patterns:
# sda_randread_4k_nj64_io128_153022.log
# parallel_seqread_4k_nj64_io128_153022.log
# stress_randwrite_128k_nj32_io256_153022.log
RE_FILENAME = re.compile(
    r"^(?:parallel_|stress_)?(?:([a-zA-Z0-9]+)_)?"
    r"(seqread|seqwrite|randread|randwrite|randrw)_"
    r"(\d+k?)_nj(\d+)_io(\d+)_\d+\.log$",
    re.IGNORECASE,
)


def parse_iops_value(raw: str) -> float:
    """Convert IOPS string like '125k' or '1.5M' to float."""
    raw = raw.strip()
    multiplier = 1.0
    if raw.endswith("k") or raw.endswith("K"):
        multiplier = 1000.0
        raw = raw[:-1]
    elif raw.endswith("m") or raw.endswith("M"):
        multiplier = 1_000_000.0
        raw = raw[:-1]
    try:
        return float(raw) * multiplier
    except ValueError:
        return 0.0


def parse_bw_to_bps(value: float, unit: str) -> float:
    """Convert bandwidth value to Bytes/s."""
    unit_lower = unit.lower()
    if "gib/s" in unit_lower:
        return value * 1024 * 1024 * 1024
    elif "gb/s" in unit_lower:
        return value * 1000 * 1000 * 1000
    elif "mib/s" in unit_lower:
        return value * 1024 * 1024
    elif "mb/s" in unit_lower:
        return value * 1000 * 1000
    elif "kib/s" in unit_lower:
        return value * 1024
    elif "kb/s" in unit_lower:
        return value * 1000
    elif "b/s" in unit_lower:
        return value
    return value


def lat_to_us(value: float, unit: str) -> float:
    """Convert latency value to microseconds."""
    unit_lower = unit.lower()
    if unit_lower.startswith("msec") or unit_lower.startswith("ms"):
        return value * 1000.0
    elif unit_lower.startswith("sec") or unit_lower == "s":
        return value * 1_000_000.0
    elif unit_lower.startswith("nsec") or unit_lower.startswith("ns"):
        return value / 1000.0
    return value  # already usec


def extract_metadata_from_filename(filename: str) -> dict:
    """Extract disk, test type, block size, numjobs, iodepth from log filename."""
    basename = os.path.basename(filename)
    match = RE_FILENAME.match(basename)
    if match:
        disk = match.group(1) or "unknown"
        # For parallel/stress files, disk is extracted differently
        if basename.startswith("parallel_") or basename.startswith("stress_"):
            disk = "multi"
            mode = "parallel" if basename.startswith("parallel_") else "stress"
        else:
            mode = "sequential"

        return {
            "disk": disk,
            "test_type": match.group(2),
            "block_size": match.group(3),
            "numjobs": match.group(4),
            "iodepth": match.group(5),
            "mode": mode,
        }
    return {}


def parse_fio_log(filepath: str) -> List[Dict]:
    """
    Parse a single FIO plain-text log file and return a list of result dicts.
    Aggregates metrics (sum IOPS/BW, mean Latency) across all jobs/disks in the file.
    """
    if not os.path.isfile(filepath):
        return []

    with open(filepath, "r", errors="replace") as f:
        content = f.read()

    metadata = extract_metadata_from_filename(filepath)
    if not metadata:
        # Try extracting from file content
        desc_match = RE_DESCRIPTION.search(content)
        if desc_match:
            metadata = {
                "test_type": desc_match.group(1),
                "disk": desc_match.group(2),
                "block_size": desc_match.group(3),
                "numjobs": desc_match.group(4),
                "iodepth": desc_match.group(5),
                "mode": "unknown",
            }
        else:
            metadata = {
                "disk": "multi",
                "test_type": "unknown",
                "block_size": "unknown",
                "numjobs": "0",
                "iodepth": "0",
                "mode": "unknown",
            }

    # Get file modification time as the timestamp
    try:
        mtime = os.path.getmtime(filepath)
        timestamp = datetime.fromtimestamp(mtime).isoformat()
    except Exception:
        timestamp = datetime.now().isoformat()

    # Collect all metrics per direction for aggregation
    raw_metrics = {
        "read": {"iops": [], "bw_bps": [], "lat_us": []},
        "write": {"iops": [], "bw_bps": [], "lat_us": []}
    }

    # Split the log by job headers to associate latencies with directions correctly
    job_sections = re.split(r'\n[\w.@-]+: \(groupid=\d+, jobs=\d+\):', content)
    
    for section in job_sections:
        # Each job section might have a read and/or write block
        # Find where read and write blocks start
        dir_matches = list(re.finditer(r"^\s+(read|write)\s*:", section, re.M | re.IGNORECASE))
        for i, d_match in enumerate(dir_matches):
            direction = d_match.group(1).lower()
            start_pos = d_match.start()
            end_pos = dir_matches[i+1].start() if i+1 < len(dir_matches) else len(section)
            chunk = section[start_pos:end_pos]
            
            # Parse IOPS & BW
            bw_match = RE_IOPS_BW.search(chunk)
            if bw_match:
                iops = parse_iops_value(bw_match.group(2))
                bw_val = float(bw_match.group(3))
                bw_unit = bw_match.group(4)
                bw_bps = parse_bw_to_bps(bw_val, bw_unit)
                raw_metrics[direction]["iops"].append(iops)
                raw_metrics[direction]["bw_bps"].append(bw_bps)

            # Parse Latency (avg only)
            lat_match = RE_LAT_AVG.search(chunk)
            if lat_match:
                lat_unit = lat_match.group(1)
                lat_avg = float(lat_match.group(2))
                lat_avg_us = lat_to_us(lat_avg, lat_unit)
                raw_metrics[direction]["lat_us"].append(lat_avg_us)

    # ── Aggregate and Build result rows ──
    results = []
    test_type = metadata.get("test_type", "unknown").lower()
    
    def get_avg(lst):
        return sum(lst) / len(lst) if lst else 0

    read_iops = sum(raw_metrics["read"]["iops"])
    write_iops = sum(raw_metrics["write"]["iops"])
    read_bw = sum(raw_metrics["read"]["bw_bps"])
    write_bw = sum(raw_metrics["write"]["bw_bps"])
    
    read_lat = get_avg(raw_metrics["read"]["lat_us"])
    write_lat = get_avg(raw_metrics["write"]["lat_us"])

    base_row = {
        "timestamp": timestamp,
        "disk": metadata.get("disk", "unknown"),
        "test_type": test_type,
        "block_size": metadata.get("block_size", "unknown"),
        "numjobs": metadata.get("numjobs", "0"),
        "iodepth": metadata.get("iodepth", "0"),
        "mode": metadata.get("mode", "unknown"),
    }

    if test_type == "randrw":
        # For randrw, sum read/write BW and IOPS, average the latencies
        combined_iops = read_iops + write_iops
        combined_bw = read_bw + write_bw
        # Average of read and write latencies
        if read_lat and write_lat:
            combined_lat = (read_lat + write_lat) / 2
        else:
            combined_lat = read_lat or write_lat
            
        row = base_row.copy()
        row.update({
            "direction": "mixed",
            "iops_k": combined_iops / 1000.0,
            "bw_mps": combined_bw / 1_000_000.0,
            "lat_avg_us": combined_lat,
        })
        results.append(row)
    else:
        # Standard test: record separate rows if both exist, though usually only one does
        if read_iops or read_bw or read_lat:
            row = base_row.copy()
            row.update({
                "direction": "read",
                "iops_k": read_iops / 1000.0,
                "bw_mps": read_bw / 1_000_000.0,
                "lat_avg_us": read_lat,
            })
            results.append(row)
        
        if write_iops or write_bw or write_lat:
            row = base_row.copy()
            row.update({
                "direction": "write",
                "iops_k": write_iops / 1000.0,
                "bw_mps": write_bw / 1_000_000.0,
                "lat_avg_us": write_lat,
            })
            results.append(row)

    return results


def parse_directory(input_dir: str) -> List[Dict]:
    """Parse all .log files in a directory."""
    all_results = []
    log_files = sorted(Path(input_dir).rglob("*.log"))

    if not log_files:
        print(f"⚠  No .log files found in {input_dir}")
        return all_results

    for log_path in log_files:
        log_file = str(log_path)
        # Skip precondition logs
        if "precond" in os.path.basename(log_file):
            continue

        print(f"  Parsing: {log_file}")
        results = parse_fio_log(log_file)
        all_results.extend(results)

    return all_results


def _block_size_to_bytes(bs: str) -> int:
    """Convert block size string like '4k' or '128k' to numeric bytes for sorting."""
    bs = bs.lower().strip()
    match = re.match(r"(\d+)\s*(k|m|g)?", bs)
    if not match:
        return 0
    value = int(match.group(1))
    suffix = match.group(2) or ""
    if suffix == "k":
        return value * 1024
    elif suffix == "m":
        return value * 1024 * 1024
    elif suffix == "g":
        return value * 1024 * 1024 * 1024
    return value


# Custom ordering for test types to group related tests together
_TEST_TYPE_ORDER = {
    "seqread": 0,
    "seqwrite": 1,
    "randread": 2,
    "randwrite": 3,
    "randrw": 4,
}


def sort_results(results: List[Dict]) -> List[Dict]:
    """
    Sort results for easy performance analysis.
    Order: test_type (seq read → seq write → rand read → rand write → rand rw),
           block_size (increasing), numjobs (increasing), iodepth (increasing).
    """
    def sort_key(row):
        test_type = row.get("test_type", "unknown").lower()
        type_order = _TEST_TYPE_ORDER.get(test_type, 99)
        bs_bytes = _block_size_to_bytes(row.get("block_size", "0"))
        numjobs = int(row.get("numjobs", 0))
        iodepth = int(row.get("iodepth", 0))
        return (type_order, bs_bytes, numjobs, iodepth)

    return sorted(results, key=sort_key)


def write_csv(results: List[Dict], output_path: str) -> None:
    """Write parsed results to a CSV file, sorted for easy analysis."""
    os.makedirs(os.path.dirname(output_path), exist_ok=True)

    sorted_results = sort_results(results)

    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=RESULT_CSV_COLUMNS)
        writer.writeheader()
        for row in sorted_results:
            writer.writerow(row)

    print(f"✓ Wrote {len(sorted_results)} result rows to {output_path}")


def main():
    parser = argparse.ArgumentParser(
        description="FIO Result Parser — Convert plain-text FIO logs to CSV"
    )
    parser.add_argument(
        "--input", "-i",
        required=True,
        help="Path to FIO results directory or a single .log file",
    )
    parser.add_argument(
        "--output", "-o",
        default=None,
        help=f"Output directory for CSV files (default: {PARSED_RESULTS_DIR})",
    )
    args = parser.parse_args()

    input_path = os.path.abspath(args.input)
    output_dir = args.output or PARSED_RESULTS_DIR

    print("╔════════════════════════════════════════════════╗")
    print("║       FIO Result Parser                       ║")
    print("╚════════════════════════════════════════════════╝")
    print(f"  Input:  {input_path}")
    print(f"  Output: {output_dir}")
    print()

    if os.path.isfile(input_path):
        results = parse_fio_log(input_path)
        if results:
            basename = Path(input_path).stem
            csv_path = os.path.join(output_dir, f"{basename}.csv")
            write_csv(results, csv_path)
        else:
            print("⚠  No parseable data found in the file.")
    elif os.path.isdir(input_path):
        results = parse_directory(input_path)
        if results:
            # Name the CSV after the results directory
            dir_name = os.path.basename(input_path.rstrip("/"))
            csv_path = os.path.join(output_dir, f"{dir_name}.csv")
            write_csv(results, csv_path)
        else:
            print("⚠  No parseable data found in the directory.")
    else:
        print(f"✗ Path not found: {input_path}")
        sys.exit(1)

    print()
    print("Done.")


if __name__ == "__main__":
    main()
