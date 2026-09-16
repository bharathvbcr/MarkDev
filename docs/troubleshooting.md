# Troubleshooting and support

[Documentation](README.md) / Troubleshooting

## A download does not run

Check the artifact's macOS and CPU requirements in the [release index](releases/README.md). The published v0.0.3 archive is for Apple silicon and is ad-hoc signed, without notarization. A universal build setting in newer source does not add Intel support to an older archive.

Report the exact version, macOS version, and visible error. Building from source is documented in [Getting started](getting-started.md); successful signing verification alone does not prove Gatekeeper acceptance.

## A save reports a conflict or recovery problem

Another process may have changed the destination, or a previous transaction may have an uncertain outcome. Preserve the open text and review the reported state. Do not delete the recovery journal as a routine fix. The journal records save phases; it does not retain every unsaved editor revision. See [I/O and recovery](architecture.md#5-filesystem-io-recovery-and-asset-ingestion).

## A saved vault cannot open

Reconnect its volume or restore access to its folder, then try the saved entry again. If the folder moved, open and save its new location, then remove the old entry. Removing an entry deletes only the saved location. If stored list data is invalid, **Reset Saved List** clears that list after explicit selection; it does not delete the vault.

## Images, math, or diagrams do not render

- Remote images are intentionally not fetched. Use local files and check the destination relative to the document.
- A file can be rejected for format, size, pixel, or local-path validation even when another image viewer opens it.
- Unsupported LaTeX commands, Mermaid diagram types, and HTML remain outside the renderer's compatibility contract.
- Check Source mode to inspect the original input, then use [Markdown support](markdown-support.md) and the visible error to narrow the problem.

## Writing tools are unavailable

The Apple Intelligence panel distinguishes unsupported hardware, a disabled feature, a model still preparing, an unsupported language, and an unknown availability reason. Resolve the reason shown there. The optional MANVI engine has separate executable, provider, model, and authorization settings; choosing it does not enable Apple Intelligence.

## Finder preview is missing

Finder Quick Look and MarkDev's in-app peek are different surfaces. For an installed development build, run:

```sh
just preview-status
```

This checks the exact extension identifier and `/Applications/MarkDev.app` registration. It does not prove Finder selected that provider. `just preview path/to/note.md` requires a registered candidate and opens the system preview, but `qlmanage` does not report which provider rendered it.

## Export a support report

Open **Settings → Support**. Review current-process event counts, dropped events, pending writes, sink failures, and local storage health. **Export Support Report…** exports the current process's bounded event cut. A timeout or partial result remains identified as such.

**Previous Runs** inspects inactive, trusted local run files separately. **Export Previous Runs…** exports sanitized history with included/omitted counts and an explicit unknown where a scan cap prevents a complete count.

Reports use typed event codes and categorical/count metadata. They exclude note text, prompts, commands, environment values, full paths, and URL credentials or queries. Review the report before sharing it. Include the smallest reproducible non-sensitive note when filing a [bug report](https://github.com/bharathvbcr/MarkDev/issues/new?template=bug_report.md).

For vulnerabilities, use the [private reporting instructions](../SECURITY.md).
