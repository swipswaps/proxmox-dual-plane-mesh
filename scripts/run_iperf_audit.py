#!/usr/bin/env python3
"""DUAL-PLANE PATH BENCHMARKING & AUDITING PROBE."""

import subprocess
import json

TARGET_MESH_IP = "10.100.0.1"


def run_ping_test(target: str, count: int = 5) -> dict:
    cmd = ["ping", "-c", str(count), "-i", "0.2", target]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    stdout, stderr = proc.communicate(timeout=30)
    if proc.returncode != 0:
        return {"status": "failed", "error": stderr}
    lines = stdout.strip().split('\n')
    return {"status": "success", "raw": lines[-1] if lines else ""}


def run_iperf_test(target: str, port: int = 5201, duration: int = 5) -> dict:
    cmd = ["iperf3", "-c", target, "-p", str(port), "-t", str(duration), "-J"]
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    stdout, stderr = proc.communicate(timeout=duration + 30)
    if proc.returncode != 0:
        return {"status": "failed", "error": stderr}
    try:
        data = json.loads(stdout)
        sent_bps = data['end']['sum_sent']['bits_per_second']
        recv_bps = data['end']['sum_received']['bits_per_second']
        return {
            "status": "success",
            "sent_mbps": round(sent_bps / 1e6, 2),
            "recv_mbps": round(recv_bps / 1e6, 2)
        }
    except Exception as e:
        return {"status": "failed", "error": str(e)}


def main():
    print("=== DUAL-PLANE TELEMETRY & ROUTE AUDIT ===")
    print("[*] Probing Mesh Endpoint: " + TARGET_MESH_IP)
    ping_res = run_ping_test(TARGET_MESH_IP)
    print("[*] ICMP Ping Results: " + str(ping_res))
    iperf_res = run_iperf_test(TARGET_MESH_IP)
    print("[*] iperf3 Bandwidth Benchmark: " + str(iperf_res))


if __name__ == "__main__":
    main()
