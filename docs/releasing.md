# Releasing MarkDev

[Documentation](README.md) / Release process

The [justfile](../justfile), [release helper](../tools/release/release.py), and [release workflow](../.github/workflows/release.yml) own this process. Use their commands rather than manually assembling an archive. Publishing a website is separate; see [website maintenance](../website/README.md).

## Prepare a coherent source revision

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` and the matching release notes. Distinguish shipped changes from source-only work.
2. Regenerate inputs through `just generate`. Review the source and lockfile changes, then commit the intended release revision.
3. Run `just ci-local` on that revision. It verifies the pinned toolchain, release contracts, core configurations and performance, Swift tests, and universal Release build. Record actual results and any external validation still required.
4. Create the matching annotated version tag on the tested commit. Do not tag unrelated dirty work.

## Stage and verify

With the intended tag, run the canonical sequence (replace `vX.Y.Z` with the actual version):

```sh
just release-preflight vX.Y.Z
just build-release
just release-stage vX.Y.Z
just release-verify vX.Y.Z
```

Staging requires a clean checkout and checks source/tag identity, owned bundles, architectures, versions, extracted content, and checksums. Release output includes the zip, SHA-256 checksum, and source manifest.

## Upload, inspect, then publish

Push the intended branch and tag only after local validation and staging. The tag workflow repeats its gates and uploads a **draft**; it does not publish automatically. Inspect the workflow result and downloaded artifacts before publishing the draft.

`just release-draft vX.Y.Z` can resume missing uploads with the pinned GitHub CLI. It refuses observed published releases and mismatched existing assets. Do not publish concurrently with a retry: GitHub does not provide a transaction spanning the draft-state check and later upload/edit.

After publication, verify the public artifact list and update the [release index](releases/README.md), README, and website download status. Confirm CPU requirements from the actual archive rather than from current build settings.

## Signing and installation

The default Release recipe uses ad-hoc signing. `just build-release-signed` selects an exact identity and enables hardened runtime; neither path alone provides notarization. `just install` and `just install-signed` use the atomic installer and require the exact installed Quick Look extension registration.

Keep these outcomes separate in the release report: build/test success, signature validation, archive verification, installation, Gatekeeper acceptance, and physical Finder preview. A check that could not run is unverified.
