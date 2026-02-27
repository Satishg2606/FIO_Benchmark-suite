#!/usr/bin/env python3
"""
Telemetry Collector — Real-time system health monitoring.

Polls CPU, disk temperature, fan RPM, RAM, power, and network metrics
at configurable intervals and writes CSV time-series logs.
"""

import argparse
import csv
import os
import re
import signal
import subprocess
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


class HardwareMonitor:
    """Handles external monitoring tools: ipmitool, arcconf, smartctl."""

    def __init__(self, disk_type="all"):
        self.disk_type = disk_type.lower()
        self.disks = self._get_target_disks()

    def _get_target_disks(self):
        """Detect disks based on user selection: sata (sas), nvme, hdd, or all."""
        try:
            # Use lsblk to find disks and their transport/type
            cmd = ["lsblk", "-d", "-o", "NAME,TRAN,TYPE,MODEL", "-n"]
            # Python 3.6 compatibility: use stdout=subprocess.PIPE
            res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
            output = res.stdout.decode('utf-8')
            all_disks = []
            for line in output.splitlines():
                parts = line.split()
                if len(parts) < 2:
                    continue
                name, tran = parts[0], parts[1].lower()
                
                is_nvme = "nvme" in name or tran == "nvme"
                is_sata_sas = tran in ("sata", "sas", "usb")
                
                if self.disk_type == "all":
                    all_disks.append("/dev/" + name)
                elif self.disk_type == "nvme" and is_nvme:
                    all_disks.append("/dev/" + name)
                elif self.disk_type == "sata" and is_sata_sas:
                    all_disks.append("/dev/" + name)
                elif self.disk_type == "hdd" and is_sata_sas:
                    # Heuristic: HDD if model doesn't contain SSD and it's not NVMe
                    model = " ".join(parts[3:]).lower() if len(parts) > 3 else ""
                    if "ssd" not in model:
                        all_disks.append("/dev/" + name)
            return all_disks
        except (subprocess.CalledProcessError, FileNotFoundError):
            return []

    def get_ipmi_data(self):
        """Fetch CPU temp, Fan speed, and Power from IPMI."""
        data = {"cpu_temp": None, "fan_rpm": None, "power_w": None}
        try:
            # sudo ipmitool sensor provides reliable parsing
            res = subprocess.run(["sudo", "ipmitool", "sensor"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
            if res.returncode != 0:
                return data

            output = res.stdout.decode('utf-8')
            for line in output.splitlines():
                parts = [p.strip() for p in line.split("|")]
                if len(parts) < 4:
                    continue
                name, val, unit = parts[0], parts[1], parts[2]
                
                # CPU Temp
                if name == "CPU Temp" and "degrees C" in unit:
                    try:
                        data["cpu_temp"] = float(val)
                    except ValueError:
                        pass
                
                # Fan Speed (avg or first)
                if "FAN" in name and "RPM" in unit:
                    try:
                        rpm = float(val)
                        if rpm > 0:
                            if data["fan_rpm"] is None:
                                data["fan_rpm"] = rpm
                            else:
                                data["fan_rpm"] = (data["fan_rpm"] + rpm) / 2
                    except ValueError:
                        pass
                
                # PSU Consumption
                if name == "PW Consumption" and "Watts" in unit:
                    try:
                        data["power_w"] = float(val)
                    except ValueError:
                        pass
            
            if data["fan_rpm"]:
                data["fan_rpm"] = int(data["fan_rpm"])

        except (subprocess.SubprocessError, FileNotFoundError):
            pass
        return data

    def get_hba_temp(self):
        """Fetch HBA temperature from arcconf."""
        try:
            # Use absolute path for reliability
            res = subprocess.run(["sudo", "/usr/sbin/arcconf", "GETCONFIG", "1", "AD"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=8)
            output = res.stdout.decode('utf-8')
            # Look for "Temperature : 44 C/ 111 F (Normal)" - case insensitive and more flexible
            match = re.search(r"Temperature\s+:\s+(\d+)\s+C", output, re.IGNORECASE)
            if match:
                return float(match.group(1))
        except (subprocess.SubprocessError, FileNotFoundError):
            pass
        return None

    def get_all_disk_temps(self):
        """Fetch temperatures from each disk individually."""
        temps = {}
        for dev in self.disks:
            name = dev.split("/")[-1]
            temp = None
            try:
                if "nvme" in dev:
                    # sudo nvme smart-log /dev/nvme0n1
                    res = subprocess.run(["sudo", "/usr/sbin/nvme", "smart-log", dev], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
                    output = res.stdout.decode('utf-8')
                    match = re.search(r"temperature\s+:\s+(\d+)\s+C", output, re.IGNORECASE)
                    if match:
                        temp = float(match.group(1))
                else:
                    # sudo smartctl -A /dev/sda
                    res = subprocess.run(["sudo", "/usr/sbin/smartctl", "-A", dev], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=3)
                    output = res.stdout.decode('utf-8')
                    # Common IDs: 194 (Temperature_Celsius), 190 (Airflow_Temperature_Cel)
                    match = re.search(r"(194|190)\s+Temperature_Celsius.*?(\d+)\s+\(Min/Max", output, re.IGNORECASE)
                    if not match:
                        match = re.search(r"(194|190)\s+Temperature_Celsius.*?(\d+)", output, re.IGNORECASE)
                    if not match:
                        match = re.search(r"(194|190)\s+Airflow_Temperature_Cel.*?(\d+)", output, re.IGNORECASE)
                    if match:
                        temp = float(match.group(2))
                
                temps[name] = temp
            except (subprocess.SubprocessError, FileNotFoundError):
                temps[name] = None
        return temps


def get_network_mbs():
    """Return (rx_MBs, tx_MBs) since last call."""
    counters = psutil.net_io_counters()
    return float(counters.bytes_recv), float(counters.bytes_sent)


class NetworkTracker:
    """Track per-second network throughput."""

    def __init__(self):
        self._last_rx = None
        self._last_tx = None
        self._last_time = None

    def read_mbs(self):
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


class PowerTrackerFallback:
    """Track power via RAPL energy counters as fallback."""

    def __init__(self):
        self._last_energy_uj = None
        self._last_time = None
        self._rapl_file = self._find_rapl_file()

    @staticmethod
    def _find_rapl_file():
        rapl_base = Path("/sys/class/powercap")
        if rapl_base.exists():
            for pkg in sorted(rapl_base.glob("intel-rapl:*")):
                energy_file = pkg / "energy_uj"
                if energy_file.exists():
                    return str(energy_file)
        return None

    def read_watts(self):
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
                    watts = (delta_energy / 1000000.0) / delta_time
                    self._last_energy_uj = energy_uj
                    self._last_time = now
                    return round(watts, 2)

            self._last_energy_uj = energy_uj
            self._last_time = now
            return None
        except (PermissionError, FileNotFoundError, ValueError):
            return None


def get_cpu_temp_fallback():
    """Fallback: Read CPU temperature from psutil sensors."""
    try:
        temps = psutil.sensors_temperatures()
        for name in ("coretemp", "k10temp", "cpu_thermal", "acpitz"):
            if name in temps and temps[name]:
                return temps[name][0].current
    except (AttributeError, KeyError):
        pass
    return None


def collect_snapshot(power_tracker, net_tracker, hw_monitor):
    """Collect a single telemetry snapshot and individual disk temps."""
    rx_mbs, tx_mbs = net_tracker.read_mbs()
    ipmi_data = hw_monitor.get_ipmi_data()
    disk_temps = hw_monitor.get_all_disk_temps()
    
    # Summary disk temp is the maximum found
    valid_temps = [v for v in disk_temps.values() if v is not None]
    max_disk_temp = max(valid_temps) if valid_temps else None
    
    # Priority: Hardware tools -> fallback
    cpu_temp = ipmi_data["cpu_temp"] or get_cpu_temp_fallback()
    fan_rpm = ipmi_data["fan_rpm"]
    power_w = ipmi_data["power_w"] or power_tracker.read_watts()
    hba_temp = hw_monitor.get_hba_temp()

    snapshot = {
        "timestamp": datetime.now().isoformat(timespec="seconds"),
        "cpu_pct": round(psutil.cpu_percent(), 1),
        "cpu_temp_c": cpu_temp,
        "disk_temp_c": max_disk_temp,
        "fan_rpm": fan_rpm,
        "ram_pct": round(psutil.virtual_memory().percent, 1),
        "power_w": power_w,
        "hba_temp_c": hba_temp,
        "net_rx_mbs": rx_mbs,
        "net_tx_mbs": tx_mbs,
    }
    
    return snapshot, disk_temps


def run_collector(output_dir, interval, duration, disk_type):
    """Run the telemetry polling loop, writing dual CSV outputs."""
    global _running

    os.makedirs(output_dir, exist_ok=True)

    ts = datetime.now().strftime('%Y%m%d_%H%M%S')
    summary_csv_path = os.path.join(output_dir, "telemetry_" + ts + ".csv")
    disks_csv_path = os.path.join(output_dir, "telemetry_disks_" + ts + ".csv")

    power_tracker = PowerTrackerFallback()
    net_tracker = NetworkTracker()
    hw_monitor = HardwareMonitor(disk_type=disk_type)

    # Prime psutil CPU measurement
    psutil.cpu_percent(interval=0.1)

    print("╔════════════════════════════════════════════════╗")
    print("║       Telemetry Collector                     ║")
    print("╚════════════════════════════════════════════════╝")
    print("  Summary:  " + summary_csv_path)
    print("  Disk Logs:" + disks_csv_path)
    print("  Interval: " + str(interval) + "s")
    print("  Duration: " + str(duration) + "s")
    print("  Disks:    " + disk_type + " (" + str(len(hw_monitor.disks)) + " found)")
    print("  (Ctrl+C to stop early)")
    print()

    start_time = time.monotonic()
    sample_count = 0

    # Ensure disk columns are sorted for consistency
    disk_cols = sorted([d.split("/")[-1] for d in hw_monitor.disks])
    disk_fields = ["timestamp"] + disk_cols

    with open(summary_csv_path, "w", newline="") as f_sum, \
         open(disks_csv_path, "w", newline="") as f_disk:
        
        sum_writer = csv.DictWriter(f_sum, fieldnames=TELEMETRY_CSV_COLUMNS)
        sum_writer.writeheader()
        
        disk_writer = csv.DictWriter(f_disk, fieldnames=disk_fields)
        disk_writer.writeheader()

        while _running:
            elapsed = time.monotonic() - start_time
            if elapsed >= duration:
                break

            snapshot, disk_temps = collect_snapshot(power_tracker, net_tracker, hw_monitor)
            
            # Write summary
            row_sum = {k: (v if v is not None else "") for k, v in snapshot.items()}
            sum_writer.writerow(row_sum)
            f_sum.flush()
            
            # Write disk temperatures
            row_disk = {"timestamp": snapshot["timestamp"]}
            for d in disk_cols:
                row_disk[d] = disk_temps.get(d, "") if disk_temps.get(d) is not None else ""
            disk_writer.writerow(row_disk)
            f_disk.flush()
            
            sample_count += 1

            # Print a live summary every 5 seconds
            if sample_count % max(int(5 / interval), 1) == 0:
                s = snapshot
                cpu_str = "CPU:" + str(round(s['cpu_pct'], 1)).rjust(5) + "%"
                ram_str = "RAM:" + str(round(s['ram_pct'], 1)).rjust(5) + "%"
                cpu_t = "CPUt:" + str(int(s['cpu_temp_c'])) + "°C" if s['cpu_temp_c'] else "CPUt:N/A"
                disk_t = "DskT:" + str(int(s['disk_temp_c'])) + "°C" if s['disk_temp_c'] else "DskT:N/A"
                hba_t = "HBA:" + str(int(s['hba_temp_c'])) + "°C" if s['hba_temp_c'] else "HBA:N/A"
                fan_str = "Fan:" + str(s['fan_rpm']) + "rpm" if s['fan_rpm'] else "Fan:N/A"
                net_str = "Net:↓" + str(round(s['net_rx_mbs'], 1)) + "/↑" + str(round(s['net_tx_mbs'], 1)) + "MB/s"
                
                print("  [" + str(int(elapsed)).rjust(4) + "s] " + cpu_str + " " + ram_str + " " + cpu_t + " " +
                      disk_t + " " + hba_t + " " + fan_str + " " + net_str)

            time.sleep(interval)

    print()
    print("✓ Collected " + str(sample_count) + " samples → " + summary_csv_path)


def main():
    parser = argparse.ArgumentParser(
        description="Telemetry Collector — real-time system health monitoring"
    )
    parser.add_argument(
        "--output", "-o",
        default=TELEMETRY_LOGS_DIR,
        help="Output directory (default: " + TELEMETRY_LOGS_DIR + ")",
    )
    parser.add_argument(
        "--interval",
        type=float,
        default=TELEMETRY_INTERVAL_SEC,
        help="Polling interval in seconds (default: " + str(TELEMETRY_INTERVAL_SEC) + ")",
    )
    parser.add_argument(
        "--duration",
        type=float,
        default=TELEMETRY_DEFAULT_DURATION_SEC,
        help="Max duration in seconds (default: " + str(TELEMETRY_DEFAULT_DURATION_SEC) + ")",
    )
    parser.add_argument(
        "--disk-type",
        choices=["all", "nvme", "sata", "hdd"],
        default="all",
        help="Type of disks to monitor temperature (default: all)",
    )
    args = parser.parse_args()

    run_collector(
        output_dir=args.output,
        interval=args.interval,
        duration=args.duration,
        disk_type=args.disk_type,
    )


if __name__ == "__main__":
    main()
