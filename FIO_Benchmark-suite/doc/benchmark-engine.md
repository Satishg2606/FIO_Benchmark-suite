# Benchmark Engine

## Overview

`src/benchmark_engine.sh` is the core FIO test runner — a refactored version of the original `fio_benchmark-2.sh`.

It preserves the interactive menu system while adding:
- **Latency percentile collection** (p50, p95, p99, p99.9)
- **Optional `--output-dir`** to override the default timestamped directory
- **`--dry-run`** mode for validation without running FIO

## Usage

```bash
# Default: interactive menus, timestamped output
sudo bash src/benchmark_engine.sh

# Custom output directory
sudo bash src/benchmark_engine.sh --output-dir /mnt/results/test1

# Dry run: generates FIO job files but doesn't execute
sudo bash src/benchmark_engine.sh --dry-run
```

## Interactive Menus

1. **Disk Selection** — All HDDs, all SSDs, or custom selection (OS disk is excluded)
2. **Block Sizes** — 4k, 128k, or both
3. **Test Types** — Sequential Read/Write, Random Read/Write, Random Read/Write Mix
4. **Preconditioning** — Optional full-disk write (destructive!) to normalize SSD state
5. **Execution Mode** — Sequential (one disk at a time), Parallel (all disks), Stress (auto-calculated), or All

## Test Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `numjobs` | 64 | Number of parallel workers |
| `iodepth` | 128, 256 | I/O queue depth |
| `runtime` | 60s | Test duration |
| `ramp_time` | 15s | Warmup before measurement |
| `percentile_list` | 50:95:99:99.9 | Latency percentiles |

## Output

Plain text `.log` files are saved in the results directory:

```
data/res-logs/fio_results_20260216_170000/
├── logs/                    # Preconditioning logs
├── sda_randread_4k_nj64_io128_170015.log
├── sda_randwrite_4k_nj64_io128_170130.log
└── parallel_seqread_128k_nj64_io256_170245.log
```

Use `result_parser.py` to convert these to CSV for the dashboard.

## Preconditioning

When enabled, writes the entire disk with `numjobs=4, iodepth=16` before each test category. This ensures SSDs are in a steady state for accurate benchmarking.

> ⚠️ **WARNING**: Preconditioning destroys all data on the selected disks!
