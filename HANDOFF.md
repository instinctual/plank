# PLANK native Apple handoff

Read `AGENTS.md` and the [native build runbook](docs/development/build/apple-native-builds.md)
first. Private deployment details remain outside Git. This handoff describes
the isolated native integration branch, not the shipping checkout.

## Current work — Vision dual displays, October 31, 2026

The operator selected Vision Pro and approved two independently configured
virtual Host displays presented in one spatial window. Display 1 is left,
Display 2 is right, top-aligned. Separate Vision windows are deferred. This
uses the existing Linux Host topology protocol; macOS Host multidisplay is
outside the task. See [the plan](docs/development/plans/vision-dual-display.plan).

Both root and Client are now on `avp-dual-display`, branched from the clean
`native-builds` checkpoints root `8325c113b25d02a7316691a30bc186f62c3d431f`
and Client `73d1f74a8c67037bd5e35c849e543e1440b9a7fd`. The worktree directory
is still `build/worktrees/native-builds`; its directory name is not its branch.
Shipping main is untouched. Keep the native dependency pins below.

Implemented bookmark add/edit/persistence, combined width and maximum height,
8192-pixel width rejection, dual-mode startup and retry, one-window scaled-span
negotiation and shared aspect-fit mapping for video/cursor/pointer capture.
The native Mac pilot explicitly retains separate-window negotiation. New pure
checks cover bookmark persistence, geometry, mode order, limits and input edges.
Hosted run [41275004438](https://github.com/instinctual/plank/actions/runs/41275004438)
at root `c830ea3` / Client `46e6362b` passed Vision device/simulator and iPad
device/simulator builds. All 62 new canvas checks and 12 bookmark-session checks
passed, as did the existing 86 native Mac multiple-screen checks. The Mac job
again failed the existing 2 MiB reference-image loopback assembly deadline.
No deadline/size limit has changed. Follow-up diagnostics report only byte
progress and sender budget state, never image data or peer identities.

The combined desktop scene now uses one named Window, so Open Session reveals
the existing viewport instead of creating another stream owner. This follow-up
still needs its hosted build. Actual headset acceptance and TestFlight delivery
are pending. The protected Vision environment now permits only this exact
additional branch alongside the two already-approved native branches.

## Imported integration baseline — October 21, 2026

The baseline was prepared in `build/worktrees/native-builds`, including its linked Client at
`apps/client`, on branches named `native-builds`. The canonical root and
Client stay on shipping `main`; no native pilot has replaced the shipping
Ubuntu Qt or macOS SDL/Metal application.

The operator authorized reviewing and integrating the contributor's dependent
native slices in order, preserving our hosted CI corrections. Client integration
is `73d1f74a8c67037bd5e35c849e543e1440b9a7fd`, pushed before the parent gitlink.

| Contributor PR | Exact imported head | Scope |
| --- | --- | --- |
| [Client fork #11](https://github.com/cnoellert/plank-client/pull/11) | `73add890536d38b42b11d687cd0a68ddd48ae90e` | Optional Mac USB tablet sharing, consent and exclusive capture lease |
| [Client fork #12](https://github.com/cnoellert/plank-client/pull/12) | `b45921542e9e7224fc6787ee0abc09e2d10e5e8a` | Source-rectangle display mapping, multiple windows, focus and scrolling |
| [Client fork #13](https://github.com/cnoellert/plank-client/pull/13) | `c3dfc42bb4272ab18616e022b441fdbbe9497bc1` | Separate iPad pilot, Pencil and authenticated pen/key sharing |
| [Client fork #14](https://github.com/cnoellert/plank-client/pull/14) | `15095c18510552d21f4f1b9a9b882c4f569512dd` | Optional reference image, artist controls, Fit/2×/Hand, Settings/browser lifetime |

Original commits and authorship are preserved in four merge checkpoints.
The last slice already contains a contributor merge of shipping Client
`58f4df097c1cdf11bf6b4b429701f156e2b10109`. Its older Linux changes are inherited
history, not new native features. Do not merge this older product snapshot back
over current shipping Client `67a94f94d711e81f470b985001ca3eae37f5abad`.
No camera, capture-quality or obsolete side branch was imported.

## Review and integration corrections

Source review covered peer authentication/approval, bounded queues and image
allocation, key/contact retirement, generation isolation, USB capture ownership,
source-rectangle rendering/input and Settings/window lifetime. Reference images
are deliberately reduced-resolution SDR JPEG previews, not colour-critical
10-bit stream output. Their default-off sender control and cryptographic binding
to the current approved Pencil session are retained.

Merge resolution preserves our numeric CI build identity, branch labels,
Release configuration, SDK27 Rust `strip=none` workaround, simulator presentation
callback guard and existing protected Vision distribution identity. iPad gets
separate numeric metadata and a visible branch/build label; it is not a shipping
Client replacement.

The imported Mac test driver omitted the new shared key-ownership source from
three compile commands. This is repaired, and the previously unwired sharing,
crypto, image, Pencil, Settings and iPad policy tests are now required in hosted
CI. Socket fixtures bind to loopback rather than all interfaces. Public native
Mac build labels in imported documentation were expanded to avoid confusion
with deployment machine names; no deployment values or private evidence were
added.

## Validation state and next action

Local and source checks:

- 22 root native CI/delivery regression tests passed locally (mocked Apple APIs).
- Three Client build-integration tests and shell syntax/whitespace checks passed.
- Gitleaks scanned 186 newly reachable commits with no detected secrets.
- The public new-content privacy gate passed. This is not a complete
  certification of arbitrary historical assets or upstream dependencies.
- The existing seven recipe source-verification tests require Python 3.12+
  and are run on Actions, not the local Python 3.9 interpreter.

[Hosted run 39724301095](https://github.com/instinctual/plank/actions/runs/39724301095)
built parent `63d55e7e6dc35e006e0946a7d5bf3f5ff47b607b` with Client
`88089801fc7e107d5254a93de2feab5071ff775d`:

| Target | Result |
| --- | --- |
| Vision device | Passed; unsigned archive and matching symbols |
| Vision simulator | Passed; unsigned simulator app |
| iPad device | Passed; unsigned archive and matching symbols |
| iPad simulator | Passed; unsigned simulator app |
| Native Mac | Failed in the mandatory reference-image loopback check, before application compilation |

The first run exposed missing iPad archive installation settings. Explicit
application install and dSYM settings now match the Vision contract; the
device archive presence and UUID gates passed on the second run.

The unresolved Mac failure is a maximum-size 2 MiB reference image exceeding
the receiver's three-second assembly deadline on loopback. Mac policy, tablet
sharing and image crypto/wire checks passed first. Later image codec, Pencil
and iPad component checks did not run because the socket check stops the job.
The assertion now includes the existing bounded close reason and receiving
state. Its deadlines, size limits and acceptance criteria are unchanged.

[TCP comparison run 39725191900](https://github.com/instinctual/plank/actions/runs/39725191900)
at parent `02f5dde8743c0e832d6ce2ac463f2810d8aef9d2` reproduced the same
timeout with TCP_NODELAY enabled. That unproven change was withdrawn rather
than retained as a supposed fix. Current Client `73d1f74a` has the exact same
Git tree as tested Client `88089801`; no new complete passing build is claimed.
The extra full shipping-product workflows triggered by these branch pushes
were deliberately canceled; they are not hardware or ordinary Mac-worker gates.

Next: measure the image sender's chunk scheduling/completion and receiver's
assembly progress on the hosted runner, then fix the demonstrated bottleneck.
Do not assume TCP aggregation caused it, lengthen the deadline, reduce the
maximum-frame test or bypass the failed check to claim readiness. Once fixed,
run the remaining Mac checks and all five applications at the same exact source.
This is a committed review/integration checkpoint, not a TestFlight-ready build.
No new signing, TestFlight upload, installation, release or physical device
acceptance was performed.

Hosted build/test success still does not prove streaming, latency, visual
fidelity, pressure, OS gesture arbitration or final Host receipt of releases.
The source's device-test narratives are contributor evidence for their stated
builds, not fresh acceptance of our combined tree.

## Dependency and production boundaries

Native recipes still deliberately select:

| Input | Commit |
| --- | --- |
| Transport parent | `6c6865562713d265a657dec613f55169ccb379b2` |
| Kymux | `8654cfece0fe5f3ab35177f520ca9378f6d35c24` |
| Client common-C integration | `036df96f2d1577af7a1b08c05d87a5218fff7c9b` |
| Public raw-tablet protocol | `029721f9b60833d36aa31f4da558cf8325e111ca` |
| Public tablet-setup protocol | `73a3743e10c8031b7f5f34105d22f207e8783397` |

Kymux has the same tree as our dependency merge `04c3f179`, retaining both stale
video retirement and completed audio/video queue draining. Do not silently
replace this native transport parent with current PLANK main or mix its header
contract with a newer gitlink. Historical independent verification passed 33
media component and 53 parent transport unit tests; that is unchanged-input
evidence, not a new runtime pass.

[Client coordination issue #9](https://github.com/instinctual/plank-client/issues/9)
remains the integration contract. Before production promotion, reconcile
persistent pre-credential Host trust, exact-format decoder fallback, current
audio clock/input/transport semantics, and the ordinary Mac capture worker
against shipping main. The documented unexpected-failure release ordering still
needs deterministic normal/error/cancel proof and held-input reconnect testing;
sender submission is not a Host acknowledgment. Do not hide this with a second
sender or an unbounded shutdown wait.

Same-package macOS15/macOS27 runtime tests remain required. The Host stays
macOS27-only. Native iPad currently targets iPadOS26 with SDK27+; Vision uses its
pinned deployment target. Multidisplay, Space/focus transitions, local/raw/shared
tablet ownership, USB/network interruption, frame precision and a real audio
soak remain device gates. No device availability or author-reported test should
be invented.

## Retained baseline and delivery

Before this import, native Client `693a14a68e60e5434251b86fa158b88a2f410a6c`
was qualified by [hosted run 37825883027](https://github.com/instinctual/plank/actions/runs/37825883027):
all three original builds passed and Vision 0.1.0 build5.1 was uploaded. Its
initial compliance failure was subsequently resolved on the existing build;
Apple reported `VALID` / `IN_BETA_TESTING`. Do not rebuild it solely because that
historical Actions run remains red. Physical headset acceptance was not recorded.

The new ordinary builds are unsigned inspection archives/ZIPs, not installable
TestFlight packages. iPad has no distribution setup in our workflow. Existing
Vision-only signing remains protected and manual. Do not reuse Developer ID or
notarization credentials for App Store distribution.

For current shipping packages, releases and runtime state, use the canonical
`main` checkout's HANDOFF. This native worktree's old release and device-session
transcript has been replaced by this focused continuation state; history remains
in Git.
