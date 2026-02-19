#!/usr/bin/env python3
"""
FIO Benchmark Suite — API Server

Lightweight FastAPI server that reads from local CSV/text files.
Provides REST endpoints for results and disks, plus a WebSocket
endpoint for live telemetry streaming.

Start:
    cd FIO_Benchmark-suite
    uvicorn src.api_server:app --reload --port 8000
"""

import asyncio
import csv
import json
import os
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List

from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import (
    CORS_ORIGINS,
    PARSED_RESULTS_DIR,
    RES_LOGS_DIR,
    TELEMETRY_LOGS_DIR,
)

# ── App ──────────────────────────────────────────────────────────────────────
app = FastAPI(
    title="FIO Benchmark Suite API",
    version="1.0.0",
    description="REST + WebSocket API for the FIO Benchmark Suite",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=CORS_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ── Helpers ──────────────────────────────────────────────────────────────────

def read_csv_file(filepath: str) -> List[Dict]:
    """Read a CSV file and return list of dicts."""
    rows = []
    with open(filepath, "r", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            # Convert numeric fields
            for key in row:
                val = row[key]
                if val == "":
                    row[key] = None
                    continue
                try:
                    if "." in val:
                        row[key] = float(val)
                    else:
                        row[key] = int(val)
                except (ValueError, TypeError):
                    pass
            rows.append(row)
    return rows


def list_csv_files(directory: str) -> List[Dict]:
    """List CSV files in a directory with metadata."""
    results = []
    dirpath = Path(directory)
    if not dirpath.exists():
        return results

    for csv_file in sorted(dirpath.glob("*.csv")):
        stat = csv_file.stat()
        results.append({
            "name": csv_file.stem,
            "filename": csv_file.name,
            "size_bytes": stat.st_size,
            "modified": datetime.fromtimestamp(stat.st_mtime).isoformat(),
        })
    return results


# ── Disk Discovery ──────────────────────────────────────────────────────────

@app.get("/api/disks")
async def get_disks():
    """List available disks using lsblk."""
    try:
        result = subprocess.run(
            ["lsblk", "-Jnd", "-o", "NAME,SIZE,TYPE,MODEL,ROTA,MOUNTPOINT"],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail="lsblk failed")

        data = json.loads(result.stdout)
        disks = []
        for dev in data.get("blockdevices", []):
            if dev.get("type") not in ("disk",):
                continue
            # Determine if it's the OS disk (has a mountpoint of /)
            is_os_disk = dev.get("mountpoint") == "/"
            disk_type = "HDD" if dev.get("rota") else "SSD"
            disks.append({
                "name": dev["name"],
                "size": dev.get("size", ""),
                "model": (dev.get("model") or "").strip(),
                "type": disk_type,
                "is_os_disk": is_os_disk,
            })

        return {"disks": disks}
    except FileNotFoundError:
        raise HTTPException(status_code=500, detail="lsblk not found")
    except json.JSONDecodeError:
        raise HTTPException(status_code=500, detail="Failed to parse lsblk output")


# ── Benchmark Results ────────────────────────────────────────────────────────

@app.get("/api/results")
async def list_results():
    """List available parsed result sets (CSV files)."""
    return {"results": list_csv_files(PARSED_RESULTS_DIR)}


@app.get("/api/results/{name}")
async def get_result(name: str):
    """Get parsed CSV data for a specific result set."""
    csv_path = os.path.join(PARSED_RESULTS_DIR, f"{name}.csv")
    if not os.path.isfile(csv_path):
        raise HTTPException(status_code=404, detail=f"Result set '{name}' not found")

    data = read_csv_file(csv_path)
    return {"name": name, "count": len(data), "data": data}


@app.get("/api/results/{name}/summary")
async def get_result_summary(name: str):
    """Get summary statistics for a result set."""
    csv_path = os.path.join(PARSED_RESULTS_DIR, f"{name}.csv")
    if not os.path.isfile(csv_path):
        raise HTTPException(status_code=404, detail=f"Result set '{name}' not found")

    data = read_csv_file(csv_path)

    # Group by test_type + direction
    groups = {}
    for row in data:
        key = f"{row.get('test_type', 'unknown')}_{row.get('direction', 'unknown')}"
        if key not in groups:
            groups[key] = []
        groups[key].append(row)

    summary = {}
    for key, rows in groups.items():
        iops_vals = [r.get("iops", 0) or 0 for r in rows]
        bw_vals = [r.get("bw_kbs", 0) or 0 for r in rows]
        lat_vals = [r.get("lat_mean_us", 0) or 0 for r in rows]

        summary[key] = {
            "count": len(rows),
            "iops_avg": round(sum(iops_vals) / len(iops_vals), 1) if iops_vals else 0,
            "iops_max": max(iops_vals) if iops_vals else 0,
            "bw_kbs_avg": round(sum(bw_vals) / len(bw_vals), 1) if bw_vals else 0,
            "lat_mean_us_avg": round(sum(lat_vals) / len(lat_vals), 1) if lat_vals else 0,
        }

    return {"name": name, "summary": summary}


# ── Raw Logs ─────────────────────────────────────────────────────────────────

@app.get("/api/logs")
async def list_log_dirs():
    """List raw FIO result directories."""
    dirs = []
    base = Path(RES_LOGS_DIR)
    if base.exists():
        for d in sorted(base.iterdir()):
            if d.is_dir():
                log_count = len(list(d.glob("*.log")))
                dirs.append({
                    "name": d.name,
                    "log_count": log_count,
                    "modified": datetime.fromtimestamp(d.stat().st_mtime).isoformat(),
                })
    return {"log_dirs": dirs}


# ── Telemetry ────────────────────────────────────────────────────────────────

@app.get("/api/telemetry")
async def list_telemetry_sessions():
    """List available telemetry CSV sessions."""
    return {"sessions": list_csv_files(TELEMETRY_LOGS_DIR)}


@app.get("/api/telemetry/{session}")
async def get_telemetry_session(session: str):
    """Get telemetry time-series data for a session."""
    csv_path = os.path.join(TELEMETRY_LOGS_DIR, f"{session}.csv")
    if not os.path.isfile(csv_path):
        raise HTTPException(status_code=404, detail=f"Session '{session}' not found")

    data = read_csv_file(csv_path)
    return {"session": session, "count": len(data), "data": data}


@app.get("/api/telemetry/latest/data")
async def get_latest_telemetry():
    """Get the most recent telemetry session data."""
    sessions = list_csv_files(TELEMETRY_LOGS_DIR)
    if not sessions:
        raise HTTPException(status_code=404, detail="No telemetry sessions found")

    latest = sessions[-1]
    csv_path = os.path.join(TELEMETRY_LOGS_DIR, latest["filename"])
    data = read_csv_file(csv_path)
    return {"session": latest["name"], "count": len(data), "data": data}


# ── WebSocket: Live Telemetry ────────────────────────────────────────────────

@app.websocket("/ws/telemetry")
async def websocket_telemetry(websocket: WebSocket):
    """Stream live telemetry data over WebSocket at ~1 Hz."""
    await websocket.accept()

    try:
        import psutil as _psutil
    except ImportError:
        await websocket.send_json({"error": "psutil not available on server"})
        await websocket.close()
        return

    # Local trackers for this connection
    _psutil.cpu_percent(interval=0.1)
    last_net = _psutil.net_io_counters()
    last_time = time.monotonic()

    try:
        while True:
            await asyncio.sleep(1.0)

            cpu_pct = _psutil.cpu_percent(interval=None)
            mem = _psutil.virtual_memory()

            # CPU temp
            cpu_temp = None
            try:
                temps = _psutil.sensors_temperatures()
                for name in ("coretemp", "k10temp", "cpu_thermal", "acpitz"):
                    if name in temps and temps[name]:
                        cpu_temp = temps[name][0].current
                        break
                if cpu_temp is None:
                    for entries in temps.values():
                        if entries:
                            cpu_temp = entries[0].current
                            break
            except (AttributeError, KeyError):
                pass

            # Network delta
            net = _psutil.net_io_counters()
            now = time.monotonic()
            dt = now - last_time
            rx_mbs = ((net.bytes_recv - last_net.bytes_recv) / dt) / (1024 * 1024) if dt > 0 else 0
            tx_mbs = ((net.bytes_sent - last_net.bytes_sent) / dt) / (1024 * 1024) if dt > 0 else 0
            last_net = net
            last_time = now

            snapshot = {
                "timestamp": datetime.now().isoformat(timespec="seconds"),
                "cpu_pct": round(cpu_pct, 1),
                "cpu_temp_c": round(cpu_temp, 1) if cpu_temp else None,
                "ram_pct": round(mem.percent, 1),
                "net_rx_mbs": round(max(rx_mbs, 0), 3),
                "net_tx_mbs": round(max(tx_mbs, 0), 3),
            }

            await websocket.send_json(snapshot)

    except WebSocketDisconnect:
        pass
    except Exception:
        await websocket.close()


# ── Health ───────────────────────────────────────────────────────────────────

@app.get("/api/health")
async def health():
    return {"status": "ok", "timestamp": datetime.now().isoformat()}


# ── Entry point ──────────────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("api_server:app", host="0.0.0.0", port=8000, reload=True)
