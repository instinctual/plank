# Wacom focus and retained-contact PR review

Reviewed 2026-09-25 on root branch `review-wacom-lifecycle`, based on root
`0c4d9df3a1e3257a30785bc9655a9882621c65dd`. This is a review, not an
implementation, approval, merge or hardware acceptance. The subsequent
operator-approved implementation is recorded below; findings in the original
review refer to the PR heads in the table, not the repaired follow-up.

## Approved implementation follow-up

The operator approved fixing the findings and retaining both approaches.
Client `9961eba21910c5ae3695e24217e8f78694965c6e` includes PR7 (attributed
cherry-pick `696e4e7e`) and permanent focus-policy tests. Local Host
`b8308a44c129599ef50b75c30051cee1bb55bf26` follows the original PR11 commit.
Both were integrated as gitlinks on root `review-wacom-lifecycle`. The operator
subsequently authorized merging this work into main, building all products and
closing the PRs. The source version advances to1.1.024 for those fresh packages.

- Host state reads fail explicitly if any supported component cannot be read.
  Each query permits at most four attempts on EINTR; other errors return promptly.
- Release writes advance only by complete events, finish positive short writes
  and allow at most three interrupted retries across the batch. Zero/malformed
  progress and permanent errors stop with a captured error, not an idle result.
- Successful writes are followed by readback; remaining contact or failed
  verification is not counted as a successful release. Directory failures are
  logged, and the EVIOCGRAB explanation is corrected.
- The original planner and actual syscall handling live in one small contact
  module. Tests inject syscalls into those production functions; device discovery
  and lifecycle remain in the tablet owner. No fake HID descriptors, new protocol,
  kernel-device recreation, proximity clearing or deferred release worker.
- Client production and tests share the same focus-window selection and
  transition deduplication. Physical ownership remains with the existing worker.
  Tests cover initial capture, two-output handoff, absent/removed outputs, dialogs,
  missed focus events, capture disabled and pending release/reconnect/shutdown.

The six original Host planner cases and13 new I/O cases pass with ASan/UBSan,
including25 shuffled repetitions. Both changed Host translation units compile
with warnings-as-errors. Client's actual Qt6.10.2 suite on Ubuntu26.04 reports
13 passes (11 cases plus init/cleanup), also repeated25 times. The new Host suite
is included in the existing hosted input-lifecycle gate; Client's suite is
already mandatory on macOS builds. Keyboard/permission timing guards still pass.

These are component checks, not full package builds or hardware acceptance.
The macOS27 and Flame acceptance matrix below still applies. Persistent OS/device
failures can still prevent cleanup; they are now explicit rather than success.
See HANDOFF for final integration/build provenance. The authorization to merge
does not replace the remaining live qualification below. No deployment is
requested.

## Exact scope and recommendation

| Pull request | Reviewed head | Recommendation |
| --- | --- | --- |
| [Client #7](https://github.com/instinctual/plank-client/pull/7) | `af659dbca03304897dc693dc323a419134de6147` | Keep the implementation; complete focus regression coverage and the declared macOS 27 qualification before merge. It remains a draft. |
| [Linux Host #11](https://github.com/instinctual/plank-host-linux/pull/11) | `da805d9a09c1a6493013fedef8183780b2126753` | Useful fix; harden the state-read/release-write failure paths and qualify application-level resume before merge. |

Client main is `63055b9316b002c8839dd6778b5453e035524d6a`; Host main is
`aabaf34c171a7620b7467883e6f4948a3f2659b0`. Both proposed merges are
conflict-free against those current heads. No merge was performed and the root
gitlinks remain unchanged. Neither PR currently exposes a GitHub check result;
the author's separately linked builds are evidence, not checks independently
executed in this review.

The changes complement one another but are not wire-protocol dependencies:
Client #7 makes macOS tablet acquisition/release follow actual stream-window
focus; Host #11 clears contact on retained tablet endpoints when suspend arrives,
including from Linux Clients and transport teardown. They do not change media,
encoding, cursor mapping, tablet descriptors or raw-HID framing.

## Findings

### Medium: failed evdev reads silently look like absent input state

[`read_node_state()`](https://github.com/instinctual/plank-host-linux/blob/da805d9a09c1a6493013fedef8183780b2126753/src/raw_hid_tablet.cpp#L123)
does not distinguish a failed ioctl from an idle/unsupported input component.
For example, a failed `EVIOCGKEY` leaves `held_keys` empty while pressure can
still be read and released. The tip/button release is then omitted, although
`release_retained_contacts()` can log that contact was released successfully.
Failed pressure/slot reads similarly omit the corresponding releases. A failed
directory scan returns silently.

An isolated fault test of the exact helper confirms that one interrupted key
read produces only pressure-zero and SYN_REPORT, with no BTN_TOUCH release and
no retry. This is an error-path gap, not a claim that ordinary successful reads
produce incorrect releases. It can leave the stuck-contact symptom this PR
intends to fix.

Recommended repair: represent read failure separately from unsupported/idle
state, retry EINTR within a bounded operation policy, and report partial or
failed cleanup accurately. Keep any deferred retry bounded and scoped to the
same suspended endpoint generation; do not release a new live stroke or destroy
stable tablet identities as an automatic fallback. Add syscall-boundary tests.

### Medium: an interrupted/short release write abandons the remainder

[`write_release()`](https://github.com/instinctual/plank-host-linux/blob/da805d9a09c1a6493013fedef8183780b2126753/src/raw_hid_tablet.cpp#L163)
issues one write. Its caller logs failure, closes the fd and proceeds with
suspend. There is no retry on EINTR or continuation after a positive short
write. A partial event batch can omit the trailing SYN_REPORT, so even accepted
release events need not yet form a complete input report. For a short positive
return, the logged `errno` can also be stale.

Injected EINTR and short-write tests confirm that the helper makes exactly one
attempt and leaves the remainder unsent. These are controlled boundary tests,
not observations of fault frequency on a deployed kernel.

Recommended repair: handle complete-event partial writes and EINTR with a
bounded write-all helper, distinguish zero progress/permanent failure from
success, and preserve a correct failure result. Verify held-contact state when
claiming successful cleanup. Test interruptions, partial progress, unavailable
nodes and already-idle nodes; never introduce an unbounded retry on the input
dispatcher.

### Low: the EVIOCGRAB explanation is inaccurate

The new [comment](https://github.com/instinctual/plank-host-linux/blob/da805d9a09c1a6493013fedef8183780b2126753/src/raw_hid_tablet.cpp#L569)
and PR description say injection is ignored whenever another evdev client holds
EVIOCGRAB. In the upstream 5.14 implementation, evdev readers/writers share the
same input handle. `evdev_grab()` grabs that handle, `evdev_write()` injects
through it, and `input_inject_event()` permits the owning handle. The events
are routed to the grabbing evdev client rather than necessarily discarded.
Sources: [evdev.c](https://github.com/torvalds/linux/blob/v5.14/drivers/input/evdev.c),
[input.c](https://github.com/torvalds/linux/blob/v5.14/drivers/input/input.c).

Correct the comment and test the actual target's grab behavior if claiming a
restriction. This does not justify changing system-wide Wacom grab settings.

## Client review

No blocking implementation defect was found in Client #7.

- The active predicate requires capture enabled and a real stream window to
  be the active-space key window of the active application. An unrelated Qt
  dialog or another application does not qualify merely because it belongs
  to the same process or because SDL retained a stale focus flag.
- All presentation outputs are checked, with a single-window fallback before
  the presentation layout exists. Moving focus between stream outputs need
  not unnecessarily release the tablet.
- The existing main event loop already has a 50 ms maximum idle wait on macOS.
  Reconciliation reuses it; no extra polling thread or timer is created. This
  is an idle-loop bound, not a promise that a busy/blocked main thread always
  responds within 50 ms.
- State-change deduplication avoids repeated backend releases and log spam.
  Capture enable/disable is reconciled after updating the capture flag.
- The backend's existing release tickets, reconnect barrier, async epochs,
  teardown and independent attachment retry remain in place. The new Boolean
  caches desired focus, not a claim that a physical attach succeeded.
- Linux raw-tablet focus handling is unchanged. macOS Host normalized pen
  forwarding is not converted to raw HID by this change. Current main's
  permission-at-launch changes survive the prospective merge.

The PR adds no automated focus tests. The isolated checks here cover its exact
C++ reconciliation methods with AppKit/SDL boundaries stubbed, not the native
OS event behavior. Permanent tests should cover initial capture, missed SDL
events, stream-to-stream handoff, true app focus loss, resume, absent backend,
and capture disabled while a stream window still has native focus.

## Host design, security and remaining questions

The pure release planner is small and straightforward. Preserving endpoint
identity and tool proximity is preferable to resetting the tablet on every
focus change. Saving the original `phys` string correctly handles later
generations reusing the original endpoints.

The scan matches the retained PLANK virtual path, rather than all Wacom vendor
IDs. It should not target a physical office tablet simply because its model
matches. No shell invocation, new network endpoint, protocol expansion or
broader capability grant is added. Existing root-owner access permits opening
the root-owned evdev nodes; future worker privilege changes must revisit this.
The scan is suspend-triggered, not a continual scan during normal pen movement.
It runs under the tablet lock, making bounded I/O handling important.

One hardware question remains separate from the proven I/O findings: evdev
injection changes input-core state, not every private hid-wacom field. The
driver's pen/touch arbitration consults cached `shared->touch_down`, which is
updated by touch-report handling. Therefore clearing tracking IDs alone does
not prove that a subsequent pen-only resume works after touch was held at
suspend. This is a source-informed qualification risk, **not a demonstrated
regression in this PR**. Test touch-down, focus loss, lift while suspended, then
resume using only the pen, with no new finger report. Source:
[hid-wacom](https://github.com/torvalds/linux/blob/v5.14/drivers/hid/wacom_wac.c).

Do not broaden this review into synthetic model-specific HID reports,
proximity resets or a tablet lifecycle rewrite without a reproduced failure.

## Validation and acceptance boundary

Performed locally without an input device, installed service, remote session or
package build:

- Inspected all changed files, the full surrounding suspend/attach lifecycle,
  Client event loop/capture ownership, backend retry/reconnect handling,
  retained Host input leases and current privilege policy.
- Checked current-main integration using `git merge-tree --write-tree` and
  whitespace validation; neither operation changed a checked-out product tree.
- Compiled exact extracted Host helpers and its six new planner tests, plus
  three syscall fault tests and two Client focus-policy tests. All 11 passed
  with GCC 14, `-Wall -Wextra -Werror`, ASan and UBSan. Fault tests assert the
  deficient current behavior; their passing is evidence of the findings, not
  evidence that failure handling is fixed.
- Rechecked both PR heads and default branch tips after analysis.

The isolated harness uses fake evdev syscalls and fake AppKit focus results;
it is not a full Host/Client build or kernel/Flame qualification. No independent
macOS 15/27, physical Wacom, pressure, margin or latency claim is made here.

The Client author reports two-output switching, pressure in Flame and USB
unplug/replug on a combined candidate, but explicitly leaves macOS 27 pending.
The Host author reports successful pen, button, pad and touch release on
hardware; Flame was closed. Its empty-descriptor UHID lifecycle tests create
no evdev nodes and therefore do not exercise the newly added read/write path.

Before acceptance, exercise the integrated current-main candidate with:

1. One and multiple Client monitors; minimize, Spaces swipe, Command-Tab,
   native dialogs and focus return, including capture deliberately disabled.
2. Tip/button held during suspend, lift while unfocused, first resumed stroke
   in Flame, pressure and Tablet Margins, with stable XInput device IDs.
3. Touch-held suspend followed by pen-only resume, plus eraser and pad buttons.
4. USB unplug/replug, transport drop, normal disconnect and reconnect.
5. Physical Host and forwarded Client tablets present together, with equal
   and different supported models, ensuring local input is unaffected.

No review/comment was posted to GitHub, no product patch applied, and no PR was
approved or merged in this review step.
