"""
Shared configuration for the FIO Benchmark Suite.
Defines paths, defaults, and constants used across all modules.
"""
import os

# --- Project Root ---
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --- Data Directories ---
DATA_DIR = os.path.join(PROJECT_ROOT, "data")
RES_LOGS_DIR = os.path.join(DATA_DIR, "res-logs")
PARSED_RESULTS_DIR = os.path.join(DATA_DIR, "parsed-results")
TELEMETRY_LOGS_DIR = os.path.join(DATA_DIR, "telemetry-logs")

# --- Ensure directories exist ---
for d in [RES_LOGS_DIR, PARSED_RESULTS_DIR, TELEMETRY_LOGS_DIR]:
    os.makedirs(d, exist_ok=True)

# --- Telemetry Defaults ---
TELEMETRY_INTERVAL_SEC = 1
TELEMETRY_DEFAULT_DURATION_SEC = 3600  # 1 hour max by default

# --- API Server ---
API_HOST = "0.0.0.0"
API_PORT = 8000
CORS_ORIGINS = [
    "http://localhost:5173",    # Vite dev server
    "http://127.0.0.1:5173",
    "http://localhost:3000",
]

# --- Benchmark Engine Path ---
BENCHMARK_ENGINE_PATH = os.path.join(PROJECT_ROOT, "src", "benchmark_engine.sh")

# --- CSV Schema for parsed results ---
RESULT_CSV_COLUMNS = [
    "timestamp",
    "disk",
    "test_type",
    "block_size",
    "numjobs",
    "iodepth",
    "mode",
    "direction",
    "iops_k",
    "bw_mps",
    "lat_avg_us",
]

# --- Telemetry CSV Schema ---
TELEMETRY_CSV_COLUMNS = [
    "timestamp",
    "cpu_pct",
    "cpu_temp_c",
    "disk_temp_c",
    "fan_rpm",
    "ram_pct",
    "power_w",
    "hba_temp_c",
    "net_rx_mbs",
    "net_tx_mbs",
]
