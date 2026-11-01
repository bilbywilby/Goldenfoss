# Architectural Principles of Small-Team Network Defense

Small IT teams gain nothing from tools that generate alerts nobody triages. Match each capability to the staff time available to run it. This model uses five vectors: **Prevent, Detect, Verify, Respond, Recover.**

## 1. Prevention

Most intrusions start with phishing, stolen credentials, or unpatched edge devices, so prevention covers identity, email, and patching as well as the network.

~~~text
              INTERNET
                  |
      +-----------+-----------+
      | GATEWAY / FIREWALL    |
      | SPI, DPI, edge IPS    |
      | DNS + egress filter   |
      +-----------+-----------+
                  |
      +-----------+-----------+
      | ROUTING POINT         |
      | (L3 core or gateway)  |
      | VLAN routing +        |
      | inter-VLAN ACLs       |
      +-----------+-----------+
                  | trunks
      +-----------+-----------+
      | ACCESS SWITCHES       |
      | (VLANs span switches) |
      +---+-------+-------+---+
          |       |       |
       VLAN 10 VLAN 20 VLAN 30
        Corp    Guest   Servers
~~~

### Edge
- Default-deny inbound, stateful rules, and DPI for application-aware policy.
- URL/content filtering. Without TLS inspection it works from SNI and DNS category, not page content. Inspection adds cost, privacy, and certificate-management burden, so adopt it deliberately.
- Vendor-managed edge IPS. It cannot see east-west traffic that stays inside a VLAN.
- **DNS and egress filtering:** use a protective DNS resolver, block outbound DNS/DoT/DoH to anything else, and default-deny outbound from servers. This is cheap and catches C2 and exfiltration. Plain DNS and DoT are easy to block; DoH is best-effort (resolver blocklists or TLS inspection).

### Segmentation and Port Security
- VLANs span access switches over trunks. Enforce inter-VLAN policy at one documented point, either the gateway or an L3 core switch.
- **Corporate:** 802.1X via RADIUS (backed by LDAP/AD), port security, DHCP snooping, and dynamic ARP inspection. Put printers and IoT devices on a restricted VLAN using MAC authentication bypass.
- **Guest:** client isolation, internet-only routing, dynamic DHCP, and rate limits.
- **Servers:** ACL-restricted, with no direct user-segment access except required services.
- **MACsec (optional):** Layer 2 encryption between switches over untrusted runs. It needs supporting hardware.

### Identity, Endpoint, Email, Patching
- MFA on all admin portals, remote access, and core services, plus a password manager.
- Managed endpoint protection on every workstation and server.
- Email filtering with SPF, DKIM, and DMARC enforcement, plus attachment/link scanning.
- Patch cadence: internet-facing and edge devices (firewall, VPN) first, within days for actively exploited CVEs. Everything else monthly.
- **Asset inventory:** you cannot spot a rogue device without a baseline.

## 2. Detection

Detection finds what prevention missed. Pick tools by the analyst time you actually have.

| Tool | Class | Staff cost |
|---|---|---|
| Wireshark | Packet analysis, on demand | Low; used during troubleshooting |
| Zeek | Network security monitoring (structured DNS/HTTP/TLS/SSH logs) | Sensor host, log storage, daily review |
| Suricata / Snort | Network IDS/IPS (signature and anomaly) | Heavy resources, daily triage, rule tuning |
| Wazuh | Host-based detection plus SIEM features (FIM, log analysis) | Server, agents, tuning |
| Graylog Open | Log aggregation and search | Server, parsers, dashboards |

Network sensors need a mirror port or tap at the routing point to see inter-VLAN traffic.

**Bridge step before a full SIEM:** ship firewall, switch, VPN, and authentication logs to one syslog host, and alert on five high-signal events:
1. New admin account or privilege change
2. Failed-login burst
3. New device on the corporate VLAN
4. Firewall or switch config change
5. Endpoint protection disabled, or a log source going silent

If nobody can own daily triage, buy MDR instead of running a SIEM.

## 3. Verification

Verification confirms the intended state still holds.

- **Discovery:** an Nmap sweep is a point-in-time cross-check, not a control. Run it monthly and diff against the asset inventory. Real rogue-device control comes from 802.1X, port security, and DHCP logs.
- **External exposure:** scan from outside monthly and confirm only authorized services answer.
- **Vulnerability scanning (OpenVAS/Greenbone):** scan internet-facing assets monthly, internal hosts at least quarterly, and after major changes. Use authenticated scans. Prioritize by CVSS, known-exploited status, asset criticality, and exposure.
- **Config audit:** automate backups and diff alerts (Oxidized or controller-based). Review firewall rules, VPN accounts, and admin rights quarterly.

## 4. Response and Recovery

For small teams this section decides ransomware outcomes.

- **Written IR plan (1-2 pages):** roles, decision authority, isolation steps, and contacts (ISP, insurer, counsel, MDR). Run a tabletop exercise yearly.
- **Backups of data and systems, not just device configs:** keep at least one copy offline or immutable, with backup credentials separate from the domain.
- **Tested restores:** restore a critical system quarterly. An untested backup is an assumption.
- **Break-glass accounts** and enough log retention to support an investigation.

## 5. Tiered Implementation

### Tier 1: Foundation (now)
- Firewall policy, VLANs, inter-VLAN ACLs, 802.1X and port security
- Protective DNS and egress filtering
- MFA, password manager, endpoint protection, email filtering
- Patch cadence and asset inventory
- Automated config backups, data backups with an offline copy, written IR plan

### Tier 2: Verification and Light Logging
- Monthly discovery diff and external scan, quarterly authenticated scans
- Quarterly change-control review
- Central syslog with the five alerts above
- Quarterly restore test and annual tabletop

### Tier 3: Advanced Detection (only with capacity)
- Zeek, Suricata, Wazuh, or Graylog, or an MDR service
- **Gate:** a named person has daily triage time, and Tier 2 alerts are tuned to be actionable.
