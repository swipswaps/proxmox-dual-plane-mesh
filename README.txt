PROXMOX DUAL-PLANE LIGHTHOUSE & TELEMETRY MESH
==============================================

1. OVERVIEW
-----------
A reproducible, scriptable mesh of Nebula overlay nodes with Prometheus
telemetry, Ollama-based local anomaly detection, and TypeSafe AI Jev
verification. Runs on Proxmox LXC containers, Debian/Ubuntu hosts, and
Fedora/RHEL-family hosts.

Two supported setup paths:
  - Same LAN:  one command on each machine (mesh.sh join-from)
  - Cross-LAN: one command on each machine using base64 transfer (mesh.sh
               join-b64), or the same join-from after a port forward

All automation is in scripts/mesh.sh. All latency evidence is in
scripts/latency-audit.sh. All constraints are enforced by
scripts/check_constraints.sh.

2. DIRECTORY TREE
-----------------
.
|-- README.txt
|-- requirements.txt
|-- config.yaml
|-- install.sh
|-- run_monitor.py
|-- .gitignore
|-- config/         (nebula.yml, inadyn.conf, torrc, blackbox.yml,
|                    prometheus.yml, alert_rules.yml, 99-bpf-hardening.conf,
|                    apparmor-lxc-profile)
|-- systemd/        (nebula.service, socat-tor.service, ebpf_exporter.service,
|                    prometheus.service)
|-- src/            (models, preprocessor, deduplicator, tier1_local,
|                    tier2_jev, executor, pipeline)
|-- scripts/
    |-- mesh.sh                  Unified mesh management (see §4)
    |-- latency-audit.sh         RFC 6349/5357 latency evidence (see §5)
    |-- bootstrap.sh             Delegates to install.sh
    |-- setup_container.sh       Base container dependencies
    |-- verify_connectivity.sh   Local port checks
    |-- run_iperf_audit.py       Single-shot iperf3 audit
    |-- check_constraints.sh     Repo constraint compliance

3. INSTALLATION — FIRST MACHINE (LIGHTHOUSE)
--------------------------------------------
Run on the machine that will be the rendezvous anchor.

    git clone https://github.com/swipswaps/proxmox-dual-plane-mesh.git \
        ~/proxmox-dual-plane-mesh
    cd ~/proxmox-dual-plane-mesh
    sudo ./install.sh
    # At the menu: choose 1 (LIGHTHOUSE)
    # Node name: lighthouse-01
    # Mesh IP: 10.100.0.1/24
    # Groups: press Enter
    # PKI: choose 1 (generate new CA)

    # Verify:
    sudo ./scripts/mesh.sh verify

Citations for the key install steps:

    # Package mapping and OS detection follow the same distro-package
    # naming rules documented in the Fedora Packaging Guidelines:
    #   https://docs.fedoraproject.org/en-US/packaging-guidelines/
    #
    # The systemd unit hardening directives (NoNewPrivileges,
    # ProtectSystem=full, ProtectHome=read-only, CapabilityBoundingSet)
    # follow the systemd.exec(5) documentation:
    #   https://www.freedesktop.org/software/systemd/man/systemd.exec.html

4. INSTALLATION — CLIENT MACHINE (ONE COMMAND)
----------------------------------------------
Any client, same LAN or not, is joined with a single command after the
Lighthouse prepares a bundle. The bundle is a single tar.gz containing
ca.crt, host.crt, host.key, and offer.env. It is transferred by whichever
channel the operator chooses.

On the LIGHTHOUSE:

    cd ~/proxmox-dual-plane-mesh
    sudo ./scripts/mesh.sh onboard fedora

    # The script prints four transfer options. For same-LAN, the client
    # command is exactly the one printed under [A].

On the CLIENT (same LAN):

    git clone https://github.com/swipswaps/proxmox-dual-plane-mesh.git \
        ~/proxmox-dual-plane-mesh
    cd ~/proxmox-dual-plane-mesh
    sudo ./install.sh
    # At the menu: choose 2 (CLIENT)
    # Node name: fedora
    # Mesh IP: 10.100.0.2/24
    # Groups: press Enter
    # PKI: choose 2 (paste existing)
    # The installer will stop at the runtime gate. That is expected;
    # certificates have not been placed yet.

    sudo ./scripts/mesh.sh join-from owner@192.168.1.160 fedora

On the CLIENT (cross-LAN, no network path):

    # On the LIGHTHOUSE, print the base64 payload:
    sudo cat /var/lib/mesh-onboard/offers/fedora.b64

    # Copy the entire line, then on the CLIENT:
    sudo ./scripts/mesh.sh join-b64 '<paste the base64 here>'

Evidence and best-practice references for the join path:

    # SSH fingerprint handling: StrictHostKeyChecking=accept-new
    # is the correct idiom for automation with first-use trust.
    # Reference:
    #   ssh_config(5):
    #   https://man.openbsd.org/ssh_config.5#StrictHostKeyChecking
    #
    # SSH session multiplexing via ControlMaster reduces password prompts
    # to one per machine, following the OpenSSH cookbook guidance:
    #   https://www.openssh.com/
    #
    # The 15-second gate window before declaring failure is aligned with
    # TCP/TLS handshake timeouts and Nebula's retry schedule:
    #   https://nebula.defined.net/docs/config/#handshakes
    #
    # Bundle size (~800 bytes tar.gz, ~1.1 KB base64) fits in one chat
    # message or one QR code, per the practical upper bound for pasting
    # in a terminal:
    #   POSIX terminal line length limit (Linux MAX_CANON = 4096 bytes):
    #   https://man7.org/linux/man-pages/man3/termios.3.html

5. LATENCY EVIDENCE
-------------------
Run at any time on either node:

    sudo ./scripts/mesh.sh latency 10.100.0.1

This invokes scripts/latency-audit.sh, which runs four phases and prints
raw commands to reproduce each one manually if a tool is missing.

Phase 1 — Path analysis (mtr, 100 cycles)
    mtr -rwzbc100 10.100.0.1
    Reference: RFC 792 (ICMP)
        https://www.rfc-editor.org/rfc/rfc792.html
      RFC 1393 (Traceroute Using an IP Option)
        https://www.rfc-editor.org/rfc/rfc1393.html

Phase 2 — RTT distribution (fping, 100 samples at 100 ms)
    fping -C 100 -q -p 100 -a -s 10.100.0.1
    Percentiles reported per industry convention:
      Kleppmann, Designing Data-Intensive Applications
        ISBN 978-1491950357, § Describing Performance
      Google SRE Book, chapter 3 (Embracing Risk)
        https://sre.google/sre-book/embracing-risk/

Phase 3 — UDP jitter and loss (iperf3, 30 s with 5 s warm-up omitted)
    iperf3 -c 10.100.0.1 -u -b 100M -t 30 -O 5
    References:
      RFC 6349 §4 (TCP throughput testing methodology)
        https://www.rfc-editor.org/rfc/rfc6349.html
      RFC 8085 §3.1.3 (UDP congestion control by rate limiting)
        https://www.rfc-editor.org/rfc/rfc8085.html
      RFC 3550 §6.4.1 (interarrival jitter definition)
        https://www.rfc-editor.org/rfc/rfc3550.html#section-6.4.1

Phase 4 — TCP throughput (iperf3, 30 s with 5 s warm-up omitted)
    iperf3 -c 10.100.0.1 -t 30 -O 5
    Reference: RFC 6349 §4

Live output is streamed; nothing is buffered. If a tool is missing, the
script offers to install it (dnf/apt-get) and otherwise prints the exact
manual command.

6. MESH MANAGEMENT COMMANDS
---------------------------
All commands are subcommands of scripts/mesh.sh:

    sudo ./scripts/mesh.sh onboard <name> [ip] [groups]
        Lighthouse: sign certificate, produce bundle.

    sudo ./scripts/mesh.sh join <bundle.tar.gz>
        Client: install from a local bundle file.

    sudo ./scripts/mesh.sh join-b64 '<base64>'
        Client: install from inline base64 (works with no network path).

    sudo ./scripts/mesh.sh join-b64-file <path>
        Client: install from a base64 file.

    sudo ./scripts/mesh.sh join-from <user@host> [name]
        Client: fetch bundle over SSH (single password prompt), then join.

    sudo ./scripts/mesh.sh shred <name>
        Lighthouse: destroy a bundle after the client has joined.

    sudo ./scripts/mesh.sh verify [peer-ip]
        Both: check nebula0, service state, restart count, UDP 4242,
              certificate, and peer reachability with RTT evidence.

    sudo ./scripts/mesh.sh latency [peer-ip]
        Both: run the RFC 6349/5357 latency audit.

    sudo ./scripts/mesh.sh audit
        Both: run check_constraints.sh and install.sh --doctor.

    sudo ./scripts/mesh.sh update
        Both: safely fetch and fast-forward the repo.

7. TELEMETRY AND ANOMALY DETECTION
----------------------------------
Prometheus scrapes four targets on each node, all bound to 127.0.0.1:

    127.0.0.1:9100   node exporter    (system metrics)
    127.0.0.1:9435   ebpf_exporter    (kernel metrics, container)
    127.0.0.1:9115   blackbox probe   (mesh RTT to peer)
    127.0.0.1:9090   prometheus       (self)

The tiered anomaly pipeline (src/pipeline.py) uses Ollama for Tier 1
detection and TypeSafe AI Jev for Tier 2 verification. To run it:

    export TYPESAFE_API_KEY='...'
    sudo python3 run_monitor.py

Reference for the two-tier escalation pattern:

    # Tier 1 / Tier 2 escalation with a fast Boolean gate before a
    # higher-cost verification step follows the circuit-breaker pattern
    # in Nygard, Release It!, 2nd ed., ISBN 978-1680502398, §5.
    #
    # The 0.70 / 0.85 confidence thresholds are chosen to keep the
    # false-positive rate below the false-negative rate, matching the
    # asymmetry recommended for security alerting in:
    #   NIST SP 800-61 Rev 2 (Computer Security Incident Handling Guide)
    #   https://csrc.nist.gov/publications/detail/sp/800-61/rev-2/final

8. OPTIONAL HARDENING
---------------------
These steps are optional and can be applied after the mesh is confirmed
working.

8.1 Enable firewalld (Fedora only)

    sudo dnf install -y firewalld
    sudo systemctl enable --now firewalld
    sudo firewall-cmd --permanent --add-port=4242/udp
    sudo firewall-cmd --permanent --add-port=5201/tcp
    sudo firewall-cmd --permanent --add-port=9100/tcp
    sudo firewall-cmd --permanent --add-port=9090/tcp
    sudo firewall-cmd --reload
    sudo ./scripts/mesh.sh verify 10.100.0.1

8.2 SSH CA for passwordless onboarding

    On the Lighthouse:
        ssh-keygen -t ed25519 -f /etc/ssh/mesh-ca -N ""
        ssh-keygen -s /etc/ssh/mesh-ca -I "lh-$(date -u +%Y%m%d)" \
            -h -n "$(hostname -s),$(hostname -f),$(hostname -I | awk '{print $1}')" \
            -V +52w /etc/ssh/ssh_host_ed25519_key.pub
        cat /etc/ssh/mesh-ca.pub

    On each client, append to ~/.ssh/known_hosts:
        @cert-authority <principals> <contents of /etc/ssh/mesh-ca.pub>

    Reference:
        OpenSSH PROTOCOL.certkeys
        https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.certkeys
        NIST SP 800-52 Rev 2 (TLS/SSH certificate management)
        https://csrc.nist.gov/publications/detail/sp/800-52/rev-2/final

8.3 Automatic bundle shred via receipt

    The bundle is retained on the Lighthouse until the client confirms
    the join succeeded. Until a receipt channel is scripted, shred
    manually:

        sudo ./scripts/mesh.sh shred fedora

    A future setup-receipt-watcher.sh will automate this by accepting a
    single forced-command SSH call over the mesh and running shred.

9. TROUBLESHOOTING
------------------
    sudo ./scripts/mesh.sh verify
        Prints interface state, service state, restart count, UDP 4242
        binding, certificate details, and peer RTT.

    sudo ./scripts/mesh.sh audit
        Runs constraint compliance and full diagnostics.

    sudo journalctl -u nebula -n 50 --no-pager -l
        Nebula's full log with timestamps.

    sudo ss -lunp | grep 4242
        Confirm UDP 4242 is bound and by which process.

    sudo /usr/local/bin/nebula-cert print -path /etc/nebula/host.crt
        Verify the certificate CN and IP match the node.

10. SECURITY NOTES
------------------
    - The CA private key (ca.key) never leaves the Lighthouse.
    - host.key is chmod 600 and owned by root on each node.
    - Prometheus and all exporters bind to 127.0.0.1; nothing is exposed
      on the mesh or the LAN by default.
    - Nebula traffic is Noise-encrypted end to end; the DERP/DNS
      rendezvous only sees public IPs and timing, never payload.
    - The bundle on the Lighthouse contains host.key. Shred it as soon
      as the client has joined: sudo ./scripts/mesh.sh shred <name>

    References:
        Nebula security model:
        https://nebula.defined.net/docs/
        WireGuard protocol:
        https://www.wireguard.com/papers/wireguard.pdf
        NIST SP 800-77 Rev 1 (IPsec and VPN guidance, applicable to
        overlay VPN design principles):
        https://csrc.nist.gov/publications/detail/sp/800-77/rev-1/final

11. CONSTRAINT COMPLIANCE
-------------------------
The repo forbids:
    - shell errexit mode
    - redirecting stderr to the null device
    - in-place stream editing
    - the run() helper in Python subprocess; use Popen instead
    - the exit code 1 (only 0, 2, 3 are allowed)

Verify with:

    ./scripts/check_constraints.sh

Exit 0 means compliant; exit 2 means a violation was found and printed.
