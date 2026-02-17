# FIO Benchmark Suite

A modular Performance Testing & Monitoring Suite built around FIO (Flexible I/O Tester).

## ⚡ Features

- **Benchmark Engine** — Interactive FIO test runner with latency percentile support (p50, p95, p99, p99.9)
- **Result Parser** — Converts FIO plain-text logs to structured CSV
- **Telemetry Collector** — Real-time CPU, RAM, disk temp, fan RPM, power & network monitoring
- **Web Dashboard** — Professional dark-mode React UI with interactive Recharts graphs
- **Live Monitoring** — WebSocket-based real-time system health view during tests

## 📁 Directory Structure

```
FIO_Benchmark-suite/
├── src/                         # All source code
│   ├── benchmark_engine.sh      # FIO test runner (interactive)
│   ├── result_parser.py         # FIO text → CSV converter
│   ├── telemetry_collector.py   # System health poller
│   ├── api_server.py            # FastAPI REST + WebSocket server
│   ├── config.py                # Shared configuration
│   └── requirements.txt         # Python dependencies
├── dashboard/                   # React + Vite web UI
├── doc/                         # Usage documentation
└── data/                        # Runtime output (auto-created)
    ├── res-logs/                # Raw FIO text results
    ├── parsed-results/          # Parsed CSV files
    └── telemetry-logs/          # Telemetry CSV sessions
```

## 🚀 Quick Start

### 1. Install Python dependencies

```bash
pip install -r src/requirements.txt
```

### 2. Run a benchmark

```bash
sudo bash src/benchmark_engine.sh
# Optional: specify output directory
sudo bash src/benchmark_engine.sh --output-dir /path/to/results
```

### 3. Parse results to CSV

```bash
python3 src/result_parser.py --input data/res-logs/fio_results_XXXXXXXX/
```

### 4. Start the dashboard

```bash
# Terminal 1: API server
uvicorn src.api_server:app --port 8000

# Terminal 2: Dashboard
cd dashboard && npm install && npm run dev
```

Open **http://localhost:5173** in your browser.

### 5. (Optional) Start telemetry collector

```bash
python3 src/telemetry_collector.py --duration 300
```

## 📖 Documentation

See the [doc/](doc/) directory for detailed guides:

- [Getting Started](doc/getting-started.md)
- [Benchmark Engine](doc/benchmark-engine.md)
- [Result Parser](doc/result-parser.md)
- [Telemetry Collector](doc/telemetry.md)
- [Dashboard](doc/dashboard.md)
