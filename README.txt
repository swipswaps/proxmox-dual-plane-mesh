PROXMOX DUAL-PLANE LIGHTHOUSE & TELEMETRY MESH
==============================================

1. SYSTEM OVERVIEW
------------------
Dual-path overlay network node inside a secured unprivileged Proxmox VE
LXC container.

Signaling channels:
  Strategy A: Direct ClearNet Dynamic DNS (inadyn) for minimal latency.
  Strategy B: Tor v3 Onion Service rendezvous for CGNAT fallback.

Benchmarking pipeline uses Blackbox Exporter, iperf3, and ebpf_exporter to
cross-benchmark both paths and flag latency spikes, jitter anomalies, DPI,
or MitM interception.

Tiered monitoring pipeline uses local open-source models (Ollama + Instructor)
for Tier 1 detection and TypeSafe AI Jev for Tier 2 verification.

All shell scripts use explicit error handling (no errexit) and exit codes
0 (success), 2 (recoverable failure), 3 (usage/permission error).

2. DIRECTORY TREE
-----------------
.
|-- README.txt
|-- requirements.txt
|-- config.yaml
|-- install.sh
|-- run_monitor.py
|-- .gitignore
|-- config/
|   |-- nebula.yml
|   |-- inadyn.conf
|   |-- torrc
|   |-- blackbox.yml
|   |-- prometheus.yml
|   |-- alert_rules.yml
|   |-- 99-bpf-hardening.conf
|   |-- apparmor-lxc-profile
|-- systemd/
|   |-- nebula.service
|   |-- socat-tor.service
|   |-- ebpf_exporter.service
|   |-- prometheus.service
|-- src/
|   |-- __init__.py
|   |-- models.py
|   |-- preprocessor.py
|   |-- deduplicator.py
|   |-- tier1_local.py
|   |-- tier2_jev.py
|   |-- executor.py
|   |-- pipeline.py
|-- scripts/
    |-- bootstrap.sh
    |-- setup_container.sh
    |-- verify_connectivity.sh
    |-- run_iperf_audit.py
    |-- check_constraints.sh

3. PREREQUISITES & PROXMOX HOST HARDENING
-----------------------------------------
Do NOT use lxc.apparmor.profile: unconfined. Unconfined profiles expose the
Proxmox host kernel to Spectre V2 (Branch Target Injection) and speculative
execution side-channel attacks via eBPF.

Run install.sh on the Proxmox host first with the container ID:

  curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/proxmox-dual-plane-mesh/main/install.sh | bash -s -- <CT_ID>

4. INSTALLATION INSIDE LXC
--------------------------
Enter the container and run install.sh:

  pct enter <CT_ID>
  curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/proxmox-dual-plane-mesh/main/install.sh | bash

The script will interactively:
  - Install all system packages
  - Install Nebula, Ollama, Semgrep
  - Prompt for node role (Lighthouse or Client)
  - Generate or import Nebula PKI certificates
  - Write /etc/nebula/config.yml
  - Deploy and enable all systemd services and monitoring configs
  - Run full-stack diagnostics

5. CREDENTIALS & CERTIFICATE PROVISIONING
-----------------------------------------
For the offline CA machine (recommended for production):
  nebula-cert ca -name "My Mesh CA"
  nebula-cert sign -name "node-01" -ip "10.100.0.1/24"

Copy ca.crt, host.crt, and host.key to /etc/nebula/ on each node.
Set restrictive permissions: chmod 600 /etc/nebula/host.key

6. VERIFICATION & TELEMETRY
---------------------------
Run connectivity verification (exit 0 = healthy, exit 2 = failures found):
  ./scripts/verify_connectivity.sh

Run active dual-path iperf3 & eBPF network audits:
  python3 scripts/run_iperf_audit.py

Run the tiered monitoring pipeline:
  export TYPESAFE_API_KEY="your_key_here"
  python3 run_monitor.py

7. TROUBLESHOOTING
------------------
Run the self-healing diagnostic suite:
  ./install.sh --doctor

Check repository constraint compliance (silent failure redirection,
direct process-module runners in Python, in-place stream editing,
errexit, disallowed exit codes):
  ./scripts/check_constraints.sh

The diagnostics check and repair:
  - TUN device availability
  - eBPF / debugfs mounts
  - Tor hidden service permissions
  - Nebula PKI validity
  - Ollama daemon and model presence
  - TypeSafe API key configuration
  - Python environment integrity

8. SERVICE MANAGEMENT
---------------------
All services are deployed and enabled automatically by install.sh:
  systemctl status nebula.service socat-tor.service ebpf_exporter.service prometheus.service

9. SECURITY NOTES
-----------------
- Never keep ca.key on client nodes or the lighthouse
- Use chmod 600 on all private keys
- Bind Prometheus and exporters to 127.0.0.1 only
- Enable BPF JIT hardening via /etc/sysctl.d/99-bpf-hardening.conf
- Run Tor under its dedicated debian-tor user
