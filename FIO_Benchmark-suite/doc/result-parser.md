# Result Parser

## Overview

`src/result_parser.py` converts FIO plain-text log files into structured CSV for visualization in the dashboard.

## Usage

```bash
# Parse all logs in a directory
python3 src/result_parser.py --input data/res-logs/fio_results_20260216/

# Parse a single log file
python3 src/result_parser.py --input data/res-logs/fio_results_20260216/sda_randread_4k.log

# Custom output directory
python3 src/result_parser.py --input data/res-logs/fio_results_20260216/ --output /tmp/csv/
```

## CSV Output Schema

| Column | Type | Description |
|--------|------|-------------|
| `timestamp` | ISO 8601 | When the test was run |
| `disk` | string | Disk name (e.g., `sda`) |
| `test_type` | string | `seqread`, `randwrite`, etc. |
| `block_size` | string | `4k` or `128k` |
| `numjobs` | int | Number of FIO workers |
| `iodepth` | int | I/O queue depth |
| `mode` | string | `sequential`, `parallel`, or `stress` |
| `direction` | string | `read` or `write` |
| `iops` | float | I/O operations per second |
| `bw_kbs` | float | Bandwidth in KB/s |
| `lat_mean_us` | float | Mean latency in microseconds |
| `lat_p50_us` | float | 50th percentile latency |
| `lat_p95_us` | float | 95th percentile latency |
| `lat_p99_us` | float | 99th percentile latency |
| `lat_p999_us` | float | 99.9th percentile latency |

## How Parsing Works

The parser uses regex to extract data from FIO's standard text output:

1. **IOPS & Bandwidth** — from lines like `read: IOPS=125k, BW=501MiB/s`
2. **Latency mean** — from lines like `lat (usec): min=152, max=58420, avg=512.34`
3. **Percentiles** — from lines like `| 50.00th=[486], 95.00th=[1020] ...`
4. **Metadata** — from filenames (`sda_randread_4k_nj64_io128_170015.log`)

Preconditioning logs are automatically skipped.
