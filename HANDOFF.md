# PLANK native Apple handoff

Read `AGENTS.md` and the [native build runbook](docs/development/build/apple-native-builds.md)
first. Private deployment details remain outside Git. This handoff describes
the isolated native integration branch, not the shipping checkout.

## Current work — October 21, 2026

Continue in `build/worktrees/native-builds`, including its linked Client at
`apps/client`. Both branches are named `native-builds`. The canonical root and
Client stay on shipping `main`; no native pilot has replaced the shipping
Ubuntu Qt or macOS SDL/Metal application.

The operator authorized reviewing and integrating the contributor's dependent
native slices in order, preserving our hosted CI corrections. Client integration
is `e2882b825e319c610eda85eb1b63d9aa6a3e66cb`, pushed before the parent gitlink.

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

Before hosted execution:

- 22 root native CI/delivery regression tests passed locally (mocked Apple APIs).
- Two Client build-integration tests and shell syntax/whitespace checks passed.
- Gitleaks scanned 186 newly reachable commits with no detected secrets.
- The public new-content privacy gate passed. This is not a complete
  certification of arbitrary historical assets or upstream dependencies.
- The existing seven recipe source-verification tests require Python 3.12+
  and are run on Actions, not the local Python 3.9 interpreter.

The initial five-target [hosted run](https://github.com/instinctual/plank/actions/runs/39723325107)
at parent `ac9b82a204745a3769a1fa9042b6320ff071103d` exposed an unexpected
reference-image socket close in the newly required Mac checks. Mac policy,
tablet-sharing and image crypto/wire checks passed before that failure. The
socket assertion now reports the existing bounded close reason and receiving
state; its assertions, rate limits and deadlines are unchanged. Follow the next
native run to diagnose that failure and record every target result before
claiming acceptance. No new signing, TestFlight upload, installation, release or
physical device acceptance is authorized by this import.

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
