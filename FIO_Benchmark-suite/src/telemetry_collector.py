#!/usr/bin/env python3
"""
Telemetry Collector — Real-time system health monitoring.

Polls CPU, disk temperature, fan RPM, RAM, power, and network metrics
at configurable intervals and writes CSV time-series logs.

Usage:
    python3 telemetry_collector.py [--output <dir>] [--interval 1] [--duration 300]
"""

import argparse
import csv
import os
import signal
import sys
import time
from datetime import datetime
from pathlib import Path

try:
    import psutil
except ImportError:
    print("ERROR: psutil is required.  Install with: pip install psutil")
    sys.exit(1)

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from config import (
    TELEMETRY_CSV_COLUMNS,
    TELEMETRY_DEFAULT_DURATION_SEC,
    TELEMETRY_INTERVAL_SEC,
    TELEMETRY_LOGS_DIR,
)

# ── Global flag for graceful shutdown ────────────────────────────────────────
_running = True


def _handle_signal(signum, frame):
    global _running
    _running = False


signal.signal(signal.SIGINT, _handle_signal)
signal.signal(signal.SIGTERM, _handle_signal)


# ── Metric collection helpers ───────────────────────────────────────────────

def get_cpu_percent() -> float:
    """Return overall CPU usage percentage."""
    return psutil.cpu_percent(interval=None)


def get_cpu_temp() -> float | None:
    """Read CPU temperature from /sys or psutil sensors."""
    # Try psutil first
    try:
        temps = psutil.sensors_temperatures()
        for name in ("coretemp", "k10temp", "cpu_thermal", "acpitz"):
            if name in temps and temps[name]:
                return temps[name][0].current
        # Fallback: any first sensor
        for entries in temps.values():
            if entries:
                return entries[0].current
    except (AttributeError, KeyError):
        pass

    # Fallback: /sys/class/thermal
    thermal_base = Path("/sys/class/thermal")
    if thermal_base.exists():
        for zone in sorted(thermal_base.glob("thermal_zone*")):
            temp_file = zone / "temp"
            try:
                raw = temp_file.read_text().strip()
                return int(raw) / 1000.0
            except (ValueError, PermissionError, FileNotFoundError):
                continue
    return None


def get_disk_temp() -> float | None:
    """Read disk temperature from hwmon or smartctl."""
    # Try /sys/class/hwmon
    hwmon_base = Path("/sys/class/hwmon")
    if hwmon_base.exists():
        for hwmon in sorted(hwmon_base.glob("hwmon*")):
            name_file = hwmon / "name"
            try:
                name = name_file.read_text().strip()
                if name in ("drivetemp", "nvme"):
                    for temp_input in sorted(hwmon.glob("temp*_input")):
                        try:
                            raw = temp_input.read_text().strip()
                            return int(raw) / 1000.0
                        except (ValueError, PermissionError):
                            continue
            except (FileNotFoundError, PermissionError):
                continue
    return None


def get_fan_rpm() -> int | None:
    """Read fan RPM from /sys/class/hwmon."""
    hwmon_base = Path("/sys/class/hwmon")
    if hwmon_base.exists():
        for hwmon in sorted(hwmon_base.glob("hwmon*")):
            for fan_input in sorted(hwmon.glob("fan*_input")):
                try:
                    raw = fan_input.read_text().strip()
                    rpm = int(raw)
                    if rpm > 0:
                        return rpm
                except (ValueError, PermissionError, FileNotFoundError):
                    continue
    return None


def get_ram_percent() -> float:
    """Return RAM usage percentage."""
    return psutil.virtual_memory().percent


def get_power_watts() -> float | None:
    """Read power from Intel RAPL (powercap) or IPMI."""
    rapl_base = Path("/sys/class/powercap")
    if rapl_base.exists():
        for pkg in sorted(rapl_base.glob("intel-rapl:*")):
            energy_file = pkg / "energy_uj"
            try:
                raw = energy_file.read_text().strip()
                # This gives cumulative energy in microjoules — we'd need two
                # reads to compute watts. For a first read, just return None.
                # The caller handles the delta calculation.
                return None  # Handled in the polling loop instead
            except (PermissionError, FileNotFoundError):
                continue
    return None


class PowerTracker:
    """Track power via RAPL energy counters (delta between reads)."""

    def __init__(self):
        self._last_energy_uj = None
        self._last_time = None
        self._rapl_file = self._find_rapl_file()

    @staticmethod
    def _find_rapl_file() -> str | None:
        rapl_base = Path("/sys/class/powercap")
        if rapl_base.exists():
            for pkg in sorted(rapl_base.glob("intel-rapl:*")):
                energy_file = pkg / "energy_uj"
                if energy_file.exists():
                    return str(energy_file)
        return None

    def read_watts(self) -> float | None:
        if not self._rapl_file:
            return None
        try:
            raw = Path(self._rapl_file).read_text().strip()
            energy_uj = int(raw)
            now = time.monotonic()

            if self._last_energy_uj is not None and self._last_time is not None:
                delta_energy = energy_uj - self._last_energy_uj
                delta_time = now - self._last_time
                if delta_time > 0 and delta_energy >= 0:
                    watts = (delta_energy / 1_000_000.0) / delta_time
                    self._last_energy_uj = energy_uj
                    self._last_time = now
                    return round(watts, 2)

            self._last_energy_uj = energy_uj
            self._last_time = now
            return None
        except (PermissionError, FileNotFoundError, ValueError):
            return None


def get_network_mbs() -> tuple[float, float]:
    """Return (rx_MBs, tx_MBs) since last call."""
    counters = psutil.net_io_counters()
    return counters.bytes_recv, counters.bytes_sent


class NetworkTracker:
    """Track per-second network throughput."""

    def __init__(self):
        self._last_rx = None
        self._last_tx = None
        self._last_time = None

    def read_mbs(self) -> tuple[float, float]:
        rx, tx = get_network_mbs()
        now = time.monotonic()

        if self._last_rx is not None and self._last_time is not None:
            dt = now - self._last_time
            if dt > 0:
                rx_mbs = ((rx - self._last_rx) / dt) / (1024 * 1024)
                tx_mbs = ((tx - self._last_tx) / dt) / (1024 * 1024)
                self._last_rx = rx
                self._last_tx = tx
                self._last_time = now
                return round(max(rx_mbs, 0), 3), round(max(tx_mbs, 0), 3)

        self._last_rx = rx
        self._last_tx = tx
        self._last_time = now
        return 0.0, 0.0


# ── Main collector loop ─────────────────────────────────────────────────────

def collect_snapshot(
    power_tracker: PowerTracker,
    net_tracker: NetworkTracker,
) -> dict:
    """Collect a single telemetry snapshot."""
    rx_mbs, tx_mbs = net_tracker.read_mbs()
    return {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "cpu_pct": round(get_cpu_percent(), 1),
        "cpu_temp_c": get_cpu_temp(),
        "disk_temp_c": get_disk_temp(),
        "fan_rpm": get_fan_rpm(),
        "ram_pct": round(get_ram_percent(), 1),
        "power_w": power_tracker.read_watts(),
        "net_rx_mbs": rx_mbs,
        "net_tx_mbs": tx_mbs,
    }


def run_collector(output_dir: str, interval: float, duration: float):
    """Run the telemetry polling loop, writing CSV output."""
    global _running

    os.makedirs(output_dir, exist_ok=True)

    session_name = f"telemetry_{datetime.now().strftime('%Y%m%d_%H%M%S')}"
    csv_path = os.path.join(output_dir, f"{session_name}.csv")

    power_tracker = PowerTracker()
    net_tracker = NetworkTracker()

    # Prime psutil CPU measurement
    psutil.cpu_percent(interval=0.1)

    print("╔════════════════════════════════════════════════╗")
    print("║       Telemetry Collector                     ║")
    print("╚════════════════════════════════════════════════╝")
    print(f"  Output:   {csv_path}")
    print(f"  Interval: {interval}s")
    print(f"  Duration: {duration}s (Ctrl+C to stop early)")
    print()

    start_time = time.monotonic()
    sample_count = 0

    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=TELEMETRY_CSV_COLUMNS)
        writer.writeheader()

        while _running:
            elapsed = time.monotonic() - start_time
            if elapsed >= duration:
                break

            snapshot = collect_snapshot(power_tracker, net_tracker)
            # Replace None with empty string for CSV
            row = {k: (v if v is not None else "") for k, v in snapshot.items()}
            writer.writerow(row)
            f.flush()
            sample_count += 1

            # Print a live summary every 5 seconds
            if sample_count % int(5 / interval) == 0:
                s = snapshot
                cpu_str = f"CPU:{s['cpu_pct']:5.1f}%"
                ram_str = f"RAM:{s['ram_pct']:5.1f}%"
                cpu_t = f"CPUt:{s['cpu_temp_c']:.0f}°C" if s['cpu_temp_c'] else "CPUt:N/A"
                disk_t = f"DskT:{s['disk_temp_c']:.0f}°C" if s['disk_temp_c'] else "DskT:N/A"
                fan_str = f"Fan:{s['fan_rpm']}rpm" if s['fan_rpm'] else "Fan:N/A"
                net_str = f"Net:↓{s['net_rx_mbs']:.1f}/↑{s['net_tx_mbs']:.1f}MB/s"
                print(
                    f"  [{int(elapsed):4d}s] {cpu_str} {ram_str} {cpu_t} "
                    f"{disk_t} {fan_str} {net_str}"
                )

            time.sleep(interval)

    print()
    print(f"✓ Collected {sample_count} samples → {csv_path}")


def main():
    parser = argparse.ArgumentParser(
        description="Telemetry Collector — real-time system health monitoring"
    )
    parser.add_argument(
        "--output", "-o",
        default=TELEMETRY_LOGS_DIR,
        help=f"Output directory (default: {TELEMETRY_LOGS_DIR})",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=TELEMETRY_INTERVAL_SEC,
        help=f"Polling interval in seconds (default: {TELEMETRY_INTERVAL_SEC})",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=TELEMETRY_DEFAULT_DURATION_SEC,
        help=f"Max duration in seconds (default: {TELEMETRY_DEFAULT_DURATION_SEC})",
    )
    args = parser.parse_args()

    run_collector(
        output_dir=args.output,
        interval=args.interval,
        duration=args.duration,
    )


if __name__ == "__main__":
    main()
