# Getting Started

## Prerequisites

| Tool | Min Version | Purpose |
|------|-------------|---------|
| `fio` | 3.x | Benchmark engine |
| `python3` | 3.10+ | Parser, telemetry, API |
| `node` | 18+ | Dashboard dev server |
| `npm` | 9+ | Dashboard package manager |

### Install FIO

```bash
# Ubuntu/Debian
sudo apt install fio

# RHEL/CentOS
sudo yum install fio

# Verify
fio --version
```

### Install Python dependencies

```bash
cd FIO_Benchmark-suite
pip install -r src/requirements.txt
```

### Install Dashboard dependencies

```bash
cd FIO_Benchmark-suite/dashboard
npm install
```

## First Run

### 1. Run a benchmark

The benchmark engine requires root access for raw-disk I/O:

```bash
sudo bash src/benchmark_engine.sh
```

Follow the interactive menus to:
1. Select disks
2. Choose block sizes (4k / 128k)
3. Choose tests (seqread, seqwrite, randread, randwrite, randrw)
4. Enable/disable preconditioning
5. Select execution mode (sequential, parallel, stress, or all)

Results are saved as plain text in `data/res-logs/fio_results_<timestamp>/`.

### 2. Parse the results

```bash
python3 src/result_parser.py --input data/res-logs/fio_results_XXXXXXXX/
```

This creates a CSV file in `data/parsed-results/`.

### 3. View results in the dashboard

```bash
# Start the API server
uvicorn src.api_server:app --port 8000

# In another terminal
cd dashboard && npm run dev
```

Open http://localhost:5173 and select a result set from the dropdown.

### 4. (Optional) Monitor system health

Run alongside a benchmark to capture telemetry:

```bash
python3 src/telemetry_collector.py --duration 600
```

The dashboard's "Live Monitoring" section will connect via WebSocket automatically.
