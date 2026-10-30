# Build artifacts

Generated packages are ignored by Git. Published GitHub release assets are a
separate, explicit publication step; collecting a package does not publish it.

```
packages/
  releases/<version>/<linux|macos>/<original-package-filename>
  candidates/<version>-<branch>/<linux|macos>/<original-package-filename>
  candidates/<version>-<branch>-macos<minimum>/macos/<original-host-package-filename>
```

Each version directory has `manifest.json` and `SHA256SUMS`. Each package also
has a neighboring `.sha256` sidecar. Run `sha256sum -c SHA256SUMS` from the
version directory (on macOS, `shasum -a 256 -c SHA256SUMS`). Filenames retain
product/version/architecture and the feature branch when applicable.

New macOS Host candidates also include the selected runtime floor in the
visible app version, filename and catalog version. For example, one branch can
retain `plank-host_1.2.02-test-host-macos26.7_arm64.pkg` and
`plank-host_1.2.02-test-host-macos27.0_arm64.pkg` under their respective version
directories. Their manifest `target_os` values are `macos-26.7` and `macos-27.0`;
the manifest branch remains `test-host`. Mainline now has one Host package for
26.7 and newer, for example `plank-host_1.2.05_arm64.pkg` under `releases/1.2.05/`,
with `target_os=macos-26.7`. The 27.0 option is a candidate comparison only.
Client and Linux naming are unchanged. Historical Host artifacts recorded as
`macos-27` or `macos-27.0` retain their original identity when re-collected. Preserve
their original manifest rather than relabelling them with a canonical new target.

`releases` means an unqualified **mainline build**, not proof of hardware
acceptance or a published release. Read each manifest's validation state.
Collection records package gates separately from functional validation; it
never upgrades a successful compile into an accepted product.

The shared collector is `scripts/package/collect-package.py`. All package builders
call it only after their package gates pass. `PLANK_ARTIFACT_ROOT` optionally
selects the package collection root; otherwise the retained canonical root's
`artifacts/packages` is used (or the source root when no canonical root is set).
Builder output arguments select scratch staging, not a second release catalog.

Use the collector again after transferring an artifact, specifying its exact
source commit, original branch, target OS and expected SHA256. Never collect an
old branch build as `main` or rename it to a newer version. Different payloads
or provenance under the same filename are rejected; increment the build version.

`qualification/` contains ignored validation reports/captures. Build trees,
signing intermediates, private keys and package extracts belong in builder
scratch/cache directories, not the package collection or tracked source.
