# macOS display mirroring decision

The operator chose PR33's mirroring implementation as the next candidate.
It fits the current single virtual workspace and capture path, uses public
Quartz configuration for the lifetime of the graphical worker, and already
includes preparation ownership and restoration. The setting is
`[general] mirror_host_displays`, default false. Physical screens remain on
and show the remote workspace; this is not a privacy or monitor-disable feature.
Client monitor count still determines the existing requested canvas, not a
new collection of independently addressed Host monitors.

The broader independent-monitor/physical-disable design is deferred. Its
plan and probes remain on `macos-session-displays` at
`7bfbb1665a4e8318780b825a4b2e827ebf4c03c4`. No probe code, private display-disable
API or additional worker is being introduced into the mirroring candidate.

## Evidence behind the decision

The authorized development Mac currently has only a PLANK virtual display,
so it cannot qualify physical-output restoration. Separate-process probes on
macOS27.2 added two virtual outputs while guarding the running desktop. Both
an arrangement test and a creation-only comparison changed the existing
virtual output from5120x2160 to4096x2160. The guard stopped only the owned probe;
the original resolution returned. Terminal, WindowServer and existing Host
processes retained their original PIDs. Temporary probe files and the one-shot
agent were removed; the final inventory matched the baseline.

The creation-only result rules out attributing that change solely to an
explicit Quartz arrangement transaction. It does not establish why the OS
chose that mode, nor a defect in PR33, which owns configuration within the
Host process. Normal and crash-owner success cases for the independent-output
probe did not pass. Presence of a private display-enable symbol was observed;
physical disable/restore was never invoked or qualified.

These observations favor keeping one layout owner and the established display
pipeline for this candidate. They are not proof that mirroring works on real
physical monitors. Hosted tests cover configuration, synthetic Quartz behavior
and actual transport/session teardown; installed tests must still establish
physical mirroring, mode/layout restoration, hotplug, crash recovery, takeover
and login/logout. Chris owns macOS26.7 qualification, alongside the existing
macOS27 gate. Keep the feature off by default and do not merge before reporting
the affected installed results.

## Current testing boundary

Preserve the existing Terminal and desktop sessions on the operator-authorized
Mac. Do not log out, reboot, terminate WindowServer or restart the Host to run
tests while those sessions are active. Builds and non-interactive regression
tests run on GitHub-hosted SDK27 workers. The signed candidate can be prepared
without another live display mutation. Private inventory, authorization and
raw evidence remain outside the repository.
