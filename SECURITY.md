# Security policy

## Report privately

Use [GitHub private vulnerability reporting](https://github.com/bharathvbcr/MarkDev/security/advisories/new).
Private reporting was verified enabled on 2026-09-13. Include the app version,
macOS version, affected path, reproducible input, and observed impact. Avoid
posting sensitive notes, credentials, or exploit details in a public issue.

This repository is in the 0.0.x app release series. The Rust crate's version is
separate from the app version. See the [release index](docs/releases/README.md)
for published artifacts; this policy does not promise maintenance of an
unpublished 0.1.x application line or a guaranteed response deadline.

## Runtime boundaries

- **Main application:** intentionally unsandboxed. The terminal executes commands with the user's authority. Validated local file operations are not process containment.
- **Quick Look:** a separate sandboxed, read-only extension built from selected canonical renderer sources. It does not link the application framework or terminal.
- **Rendering:** remote images and arbitrary script execution are excluded. Local inputs have validation and resource limits; platform decoders remain a trust boundary.
- **Rust/Swift FFI:** bounded inputs and validated UTF-16 records cross an in-process C ABI. FFI is not a sandbox; its pointer and ownership contracts still matter.
- **Assistance:** Apple Intelligence uses the on-device system model. Optional MANVI runs through separately configured executable, provider, and authority settings. Remote-provider consent and file-editing authority are explicit choices.
- **Diagnostics:** bounded local events and exports exclude note text, prompts, commands, environment values, full paths, and URL credentials or queries. Diagnostics are not remote telemetry.
- **Distribution:** ad-hoc signing is not notarization or Gatekeeper-trusted distribution. Consult the specific release's signing notes.

See [Architecture](docs/architecture.md) for descriptor-based I/O, recovery,
resource bounds, and the residual same-user pathname race before process launch.
Recovery checksums detect corruption; they do not authenticate data against a
hostile process running as the same user.
