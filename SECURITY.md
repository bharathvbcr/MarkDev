# Security Policy

MarkDev treats security and user data privacy with top priority. Because MarkDev is designed as a local-first, native Markdown editor with zero remote telemetries, your documents, notes, and system access remain entirely within your machine.

---

## Supported Versions

We provide security updates for the following versions of MarkDev:

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |
| < 0.1.0 | :x:                |

---

## Reporting a Vulnerability

If you discover a security vulnerability or potential exploit in MarkDev, please follow responsible disclosure guidelines and **do not disclose it publicly in an open GitHub issue**.

### How to Report

1. Email a report to **[security@markdev.dev](mailto:security@markdev.dev)** or open a private security advisory on GitHub if enabled.
2. Include the following details in your report:
   - A clear description of the vulnerability.
   - Exact steps or proof-of-concept (PoC) code/markdown file to reproduce the issue.
   - Operating system and MarkDev version tested.
   - Any potential impact on user data or system integrity.

### What to Expect

- **Acknowledgment**: We aim to acknowledge receipt of security reports within 48 hours.
- **Assessment**: We will investigate and confirm the issue within 5 business days.
- **Resolution**: Once verified, we will develop a patch and coordinate a release timeline with you before making any public advisory.

---

## Security Invariants in MarkDev

- **No Remote Fetching**: MarkDev never downloads remote images or scripts dynamically during Markdown rendering. Image resolution is strictly confined to local paths.
- **Terminal Isolation**: The integrated terminal emulator runs with user-scoped standard permissions and does not expose open ports or unauthenticated inter-process bridges.
- **Sandboxed FFI Boundary**: Rust/Swift FFI bridges pass validated data buffers without direct memory leaks or unsafe raw pointer escapes across actors.
