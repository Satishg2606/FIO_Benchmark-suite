# Telemetry Collector

## Overview

`src/telemetry_collector.py` polls system metrics at configurable intervals and writes CSV time-series to `data/telemetry-logs/`.

## Usage

```bash
# Default: 1-second interval, up to 1 hour
python3 src/telemetry_collector.py

# Custom interval and duration
python3 src/telemetry_collector.py --interval 2 --duration 600

# Custom output directory
python3 src/telemetry_collector.py --output /tmp/telemetry/
```

Press `Ctrl+C` to stop early.

## Collected Metrics

| Metric | Source | Non-Root |
|--------|--------|----------|
| CPU Usage % | `psutil.cpu_percent()` | ✅ |
| CPU Temperature | `/sys/class/thermal/` or psutil sensors | ✅ |
| Disk Temperature | `/sys/class/hwmon/` (drivetemp/nvme) | ⚠️ may need root |
| Fan RPM | `/sys/class/hwmon/` | ✅ |
| RAM Usage % | `psutil.virtual_memory()` | ✅ |
| Power (Watts) | Intel RAPL via `/sys/class/powercap/` | ⚠️ may need root |
| Network RX MB/s | `psutil.net_io_counters()` | ✅ |
| Network TX MB/s | `psutil.net_io_counters()` | ✅ |

Unavailable metrics are written as empty fields in the CSV.

## CSV Output

```
data/telemetry-logs/telemetry_20260216_170000.csv
```

Columns: `timestamp`, `cpu_pct`, `cpu_temp_c`, `disk_temp_c`, `fan_rpm`, `ram_pct`, `power_w`, `net_rx_mbs`, `net_tx_mbs`

## Running Alongside Benchmarks

Start the collector in a separate terminal before running the benchmark:

```bash
# Terminal 1: Start telemetry
python3 src/telemetry_collector.py --duration 7200

# Terminal 2: Run benchmark
sudo bash src/benchmark_engine.sh
```

The dashboard's Live Monitoring section automatically connects to the API server's WebSocket to show telemetry in real time.
