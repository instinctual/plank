# macOS 26.7 Host candidate review

## Final disposition

[PR #32](https://github.com/instinctual/plank/pull/32) merged on 2026-10-30 as
`19ebedb0eb33686669c9741687a2d20d65075a88`, after all seven active checks passed.
The reviewed follow-up `ef45730c4a231d7aa1b4e469688d5e05df36423a` fixes the
package-identity finding below. Candidate identities include `macos26.7` or
`macos27.0` consistently in their visible version, filename and catalog;
ordinary mainline naming and overwrite protection are preserved.

Independent follow-up checks passed 15 collector tests, all 98 CI-policy tests
and four portable Host-target checks; one Apple-compiler check was skipped
locally. Both collection orders, repeat collection, conflicting payload/source
rejection and signed/unsigned version routing are covered. All four products
passed [hosted run 41133563710](https://github.com/instinctual/plank/actions/runs/41133563710),
with PR signing intentionally skipped. Privacy and clipboard workflows passed.
The merge tree exactly matches the tested PR head.

The operator accepts 26.7 as a supported target, with Chris (cnoellert)
responsible for hardware and session validation. Main follow-up
`bd75c102d3487c6ee44b0d39a52f09b39b8756a4` records that policy and removes the
experimental wording. macOS 27 remains the default; no runtime, dispatch or
signing behavior changes in that follow-up. No installed 26.7 qualification,
signing dispatch or release was performed in this review. The earlier request
to require local 26.7 qualification before merging is superseded by this
operator decision; unperformed hardware checks are not represented as passed.

## Initial review

Reviewed 2026-10-30. This is a read-only review of
[PLANK PR #32](https://github.com/instinctual/plank/pull/32) by cnoellert,
head `a6367439ef762f6b9422c816e5e96830b048654a`, against base
`a0904d4226336f2a86959d45e54ed5f2c943a272`. The review covers all 36 changed
files. It does not add macOS 26.7 support to the current branch or authorize
signing, installation or changes to protected environments.

## Scope and recommendation

The PR adds an explicit experimental 26.7 Host deployment target, preserving
27.0 as the default and SDK 27 as the required SDK. Host runtime, protocol,
transport and dependency revisions are unchanged. The selected target reaches
the transport, native components, bundle metadata and sealed installer policy.
Availability diagnostics and Mach-O minimum checks reject newer requirements;
existing signing, entitlement, profile, permission and service-drain gates remain.

The approach is suitable for a test candidate. Correct the package identity
issue below, then qualify a signed installer on 26.7 before merging. This is
not a finding that installed 26.7 sessions already work.

## Resolved finding: distinct deployment targets shared a package identity

The workflow permits 26.7 and 27.0 on the same candidate branch and separates
their concurrency groups. However,
[`build-macos-host-pkg.sh:75`](https://github.com/cnoellert/plank/blob/a6367439ef762f6b9422c816e5e96830b048654a/scripts/package/build-macos-host-pkg.sh#L75)
constructs the filename from only product, source version, branch and
architecture. The visible application version also omits the selected floor.
Both builds therefore produce `plank-host_<version>-<branch>_arm64.pkg`.

The catalog records `target_os`, but it is not part of the destination path or
artifact identity. Using two temporary dummy artifacts and the actual collector,
collecting the 26.7 target followed by 27.0 for the same source/branch/version
reproduced this rejection:

```text
conflicting artifact/provenance; increment the version, do not overwrite
```

No real package was built or installed for that reproduction. The collector's
rejection correctly prevents replacement and should remain. The packaging needs
either a target-specific candidate identity, consistently applied to filenames,
visible versions and the catalog, or enforced separate branch/version identities
for the two packaged targets. Keep ordinary mainline naming unchanged. Add a
regression covering how both target candidates are retained without collision.

## Validation and limits

- Independently ran all 98 CI-policy tests successfully.
- Host-target, Host-permissions and Client-target packaging suites together
  passed 17 portable tests; four Apple-only tests were explicitly skipped.
- Changed shell scripts pass syntax checks; the diff passes whitespace checks.
- [Hosted build 41117442296](https://github.com/instinctual/plank/actions/runs/41117442296)
  passed policy and all four ordinary product jobs. Signing was skipped. These
  ordinary Mac Host builds use the default 27.0 target, not 26.7.
- The author's 26.7 uninstalled component-build evidence is recorded in the PR.
  It was not independently reproduced on a Mac in this review. Login-screen
  capture, desktop transitions, virtual-display lifecycle, input, audio and
  optional camera/microphone operation still need installed qualification.

The operator authorized posting
[the package-identity comment](https://github.com/instinctual/plank/pull/32#issuecomment-6533892492).
The reviewed head was unchanged when it was posted. No formal approval or merge
was submitted. The temporary review worktree and fetched review reference were
removed; current product branches and the separate native Apple work were kept.
