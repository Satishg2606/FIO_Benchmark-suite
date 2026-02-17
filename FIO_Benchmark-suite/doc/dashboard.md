# Dashboard

## Overview

The web dashboard provides a professional interface for visualizing benchmark results and monitoring system health in real time.

**Stack:** React + Vite + Recharts

## Setup

```bash
cd FIO_Benchmark-suite/dashboard

# Install dependencies
npm install

# Start dev server (port 5173)
npm run dev
```

You also need the API server running:

```bash
# From the project root
uvicorn src.api_server:app --port 8000
```

The Vite dev server proxies `/api/*` and `/ws/*` requests to the API server automatically.

## Pages

### ⚡ Dashboard (`/`)

- **Result Set Selector** — Dropdown to choose a parsed CSV result set
- **Summary Stats** — Total records, average IOPS, throughput, and latency
- **IOPS Chart** — Grouped bar chart (read vs write) per test configuration
- **Throughput Chart** — Grouped bar chart in MB/s
- **Latency Chart** — Stacked area chart showing p50, p95, p99, p99.9 percentiles
- **Live Monitoring** — Real-time sparklines for CPU, RAM, temperature, and network

### 📊 History (`/history`)

- **Result Set Table** — Browse all available parsed result sets with file sizes and dates
- **Raw Data Table** — Full data grid with all columns from the CSV
- **Charts** — Same IOPS, throughput, and latency charts for the selected set

## API Endpoints Used

| Endpoint | Purpose |
|----------|---------|
| `GET /api/results` | List available CSV result sets |
| `GET /api/results/{name}` | Get CSV data for charts |
| `GET /api/disks` | List system disks |
| `GET /api/telemetry` | List telemetry sessions |
| `WS /ws/telemetry` | Live telemetry WebSocket |

## Design

- **Dark mode** with subtle glassmorphism cards
- **Inter** font for UI, **JetBrains Mono** for data
- **Gradient accents** — blue/purple for primary, green/cyan for success metrics
- **Responsive** layout — scales from 1440px desktop down to mobile
- **Micro-animations** — hover effects, loading spinners, live pulse indicators
