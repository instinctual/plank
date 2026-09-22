# PLANK handoff

## In progress: automatic Host identity trust

Work is isolated in `build/worktrees/code-review-fixes`, root and Client branches
`code-review-fixes`, based on root `9c9d6bd` and Client `6580f794` below. It retains
the pending virtual-primary fixes; main and the unrelated primary checkout are
unchanged. No merge, release or installation is authorized by this task.

The operator approved automatic first-use trust before credentials and an
explicit Cancel / Trust Replacement Host dialog on identity changes. Trust is
separate from bookmarks; deletion/recreation is not a reset. The operator also
approved a stable machine authority across macOS login/logout and user changes,
using the existing authenticated coordinator without sharing its private key.
See `docs/development/plans/host-identity-trust.plan` and
`docs/security/host-identity-trust.md` for the residual TOFU risk and design.

Implementation is not yet qualified. First root checkpoint `b0d789f` and followups
through `c9fd940` are pushed; Client is `4e984525` (including `9a66daa4` recovery
gating). Candidate version is `1.0.153-code-review-fixes`. Client trust-store (9),
real TLS guard (5) and responsive consent UI (11) tests passed on the Ubuntu
builder. Real NvHTTP launch/authentication integration passed all 19 scenarios:
first use, known/unknown recovery, replacement cancellation/approval, changed
keys between username and password, redirects and malformed launch responses.
That integration test is now a Linux Client build gate. No network-supplied
certificate is trusted after sending credentials.

Linux certificate renewal, reconnect source checks (14), portable package-script
checks (23), CI policy checks (60) and version checks pass. The first complete
Linux Client CI build passed (run `35696323594`). macOS package filesystem tests
passed (63 checks in run `35697760809`); later coverage also checks interrupted
PEM/DER renewal. Mac runs exposed and corrected fixture/tool differences:
existing-key LibreSSL requests require `-new`, tests must select the same Qt
OpenSSL/TLS 1.3 backend as the app, and the XPC fixture must not retain itself.
Machine issuance now has an actual system-crypto test and the existing signed
XPC tests are wired into the Host build. Integrated builds must still finish;
do not call this ready to install. No live machine state has changed, and no
package has been installed. Next: complete hosted Mac/Client gates, inspect the
actual Network.framework certificate chain, then live login/logout, cross-user
handoff and replacement acceptance with matching packages.

The previous candidate and package provenance below remain valid and untouched.

## Previous candidate: virtual-primary PR repairs

The operator authorized fixing two Client findings in the coordinated Client
#6 / Linux Host #9 / root #10 series. Work uses branch `virtual-primary-fixes`
in `build/worktrees/virtual-primary-fixes` and its Client worktree. The fixes
are pushed to the author's editable `codex/virtual-primary-order` PR branches.
Main remains unchanged. Do not merge, install or publish without approval.
The operator subsequently authorized building/signing and downloading all four
test packages. The reviewed snapshot is also pushed to the maintainer-owned
`virtual-primary-fixes` branch for protected hosted signing.

Root PR base: `db868b4a8930397628c3fb10949c61c1c9ad6a2d`.
Client repair: `6580f794141b2073eae1110136d8665605eb3803`.
Root integration: `c38d5ea6952d8422f1334d5a671846a476b5c916`.
The root branch is refreshed with main's completed build notes at
`652718632be33b355df5e1fce989018c9df49f3a`; only HANDOFF conflicted.
Candidate version is 1.0.152, with the actual CI branch qualifier retained.

- Removed the Host-sized presentation-canvas override and its unused helper.
  Primary connector ordering retains the established aspect-preserving
  renderer and corresponding mouse/pen/cursor geometry.
- Bound the optional primary hint to the requested output count and an
  unambiguous horizontal layout. Manual bookmarks omit an unmappable hint
  instead of sending index 2 or rejecting an otherwise valid connection.
- Unit coverage includes 0–4 displays, every primary position, reversed
  enumeration, negative origins, ambiguous layouts, differing Host/Client
  aspect ratios and Retina logical input/cursor round trips.
- Linux Host code is unchanged from the reviewed Host #9. No transport,
  capture/encoding, physical-monitor policy or Wacom-focus change was added.

Local CI policy checks pass (60), version-contract and diff checks pass.
PR run 35677116506 passed all four products. Both Client platforms passed 25
OutputTopology tests; macOS passed 27 PlankPresentation tests. Linux compiles
the shared presentation code but its suite list does not run that test.
No new hardware acceptance is claimed. See `docs/development/virtual-primary-order-review.md`,
`protocol/output-topology.md` and `docs/releases/1.0.152.md`.

## Test package collection

All candidate builds use exact root
`0617daa52d4a136fb35cc9f12c5f446e722d39a3` and effective version
`1.0.152-virtual-primary-fixes`. Collect under
`artifacts/packages/candidates/1.0.152-virtual-primary-fixes/`; do not relabel
the earlier PR-merge artifacts with the new branch name.

- Linux Host/Client: run 35686244053, both passed and collected.
- Signed macOS Host: run 35686244115, passed and collected.
- Signed macOS Client: run 35686246368, passed and collected.

Both Mac jobs passed Developer ID signing, notarization, stapling, Gatekeeper,
package gates and temporary-keychain cleanup on disposable hosted runners.
The temporary exact-branch signing permission was removed after both passed;
the protected signing environment again permits only `main`.
No candidate was installed or published, and no live macOS acceptance is implied.

Downloaded packages are checked against each builder's recorded SHA-256 and
source/gitlink provenance before the normal local collector is run. All four
packages passed the final local checksum check and share the same source commit.
The catalog manifest and sidecars retain full hashes. Package SHA-256 values:

- Ubuntu Client: `fb55dd5f57f6e6dd495d47a4b0bae579ed5e4ebc65e324a6173ff42425130c42`.
- Linux Host: `af2aa85e379c31f02d9aa667ca03ed03063751a8a33a17df4bca248273e66d6b`.
- macOS Host: `9a57afe3678c9182c3a7be7f821e05554dae119e12167b4cd9df061918e04372`.
- macOS Client: `153931f564be1e600f2982b0dc31781aa185690382ee735e09407d52a747739b`.

The Linux Host passed all three selected-policy loss matrices at 150 Mbps,
60 fps and 0/0.5/1/3/5% controlled loss, with 6.545–8.088 ms p95 delivery.
RPM log-directory/manifest gates and the post-package input suites passed.
These are automated builder checks, not WAN or live tablet qualification.
The RPM retains the production BUILD_TESTS=OFF payload.
Package-collection tests (6), version-contract checks and diff checks passed.

## Other open PRs

All four cnoellert PRs were rechecked; no new PR or unreviewed revision appeared.
Client #7 at `af659dbca03304897dc693dc323a419134de6147` remains a separate
Wacom-focus proposal. No blocking code defect was found; native fullscreen
Spaces, focus release into local dialogs, reconnect and pressure still need
live macOS 27 qualification. It is not included in this candidate.
Linux Host #9 remains at `ebf63ac9347e461a1eaff5adc83a77724187002a`.
Client #6 and root #10 contain the authorized repairs and remain drafts.

The latest pre-repair root rebase passed all four hosted jobs in run
35675419841. Earlier paced-baseline and skipped-frame failures remain
historical evidence, not erased by later passes. Main now tests only the
selected shipping transport policy, as explicitly authorized by the operator.
Do not relax its three loss matrices or other shipping gates.

## Mainline packages and provenance

All four 1.0.151 packages passed and are collected/checksum-verified under
`artifacts/packages/releases/1.0.151/`. Nothing was installed or published.
The latest published release remains 1.0.143.

- Ubuntu Client: run 35672399443.
- Signed Mac Host: run 35672399113.
- Signed Mac Client: run 35672399343.
- Linux Host: run 35674515126.

The first three use root `c14704801ffa8c5166961c03db8f4bf6c57b08d5`;
the RPM uses `aa885d0f5b86f4e9101cff97d22c2caa9aeab66c`, which only changes
Host gate selection and its tests/docs. Exact hashes and submodule provenance
remain in each catalog manifest and main's HANDOFF at `6527186`.
Never replace or relabel those packages with this candidate.

The candidate's maintained inputs are Client `6580f794`, Linux Host
`ebf63ac9`, Kymux `158719b6`; nested dependency pins are unchanged.
Use GitHub-hosted builders, verified dependency caches and the release runbook.
Preserve the unrelated RK3576 plan, dirty HANDOFF and diagnostics in the
primary checkout. Private deployment notes stay outside Git.

## Remaining acceptance

Validate connector-primary behavior and image/input mapping with mixed
resolutions, Native and Scaled-Span, one/two local monitors and a manual
two-output bookmark on a three-monitor client. Confirm reconnect, fullscreen
transitions, mouse, pen and cursor behavior. macOS 27 live acceptance remains
outstanding; earlier macOS 15 trials are not exact-source qualification.

Mainline takeover/handoff acceptance, Wallpaper/Screen Saver hover lag and the
Linux physical-display provenance issue remain documented at main `6527186`.
This repair does not expand into those tasks or the separate Wacom-focus PR.
