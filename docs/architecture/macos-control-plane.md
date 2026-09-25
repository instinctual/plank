# macOS native control interface

Status: discovery/authentication component qualified over loopback TLS 1.3, including
a real account in the live Aqua session. Not an installable Mac Host or an
existing-Client streaming connection. Linux Host/Client behavior is unchanged.

## Native interface

`apps/host/macos/control/https-auth-server.m` uses Network.framework and
Security.framework, not a port of the Linux HTTPS server. It accepts a supplied
administrator-controlled TLS identity and explicit local IPv4 address/port.
There is no implicit wildcard listener, plaintext fallback or automatic firewall
change. TLS is exactly 1.3 and the advertised application protocol is HTTP/1.1.
Core dumps must be disabled before constructing the interface.

Implemented routes are `GET /serverinfo`, `POST /plank/auth/start` and
`POST /plank/auth/respond`, plus authenticated `GET /plank/topology`.
An explicitly supplied launch handler adds `POST /plank/launch`; otherwise it
remains 404. See `protocol/macos-preview-launch.md` for the experimental typed
contract. The same bounded auth lane invokes launch after peer-bound Bearer
validation. Failed reply delivery cancels its claim; exceptions revoke it too.
The response JSON retains the current Client contract. Peer binding comes from
the accepted connection's actual IP address; IPv4-mapped IPv6 is normalized.
Forwarded headers cannot select the peer identity. No request, account, password
or token is logged. Responses use `Cache-Control: no-store`, `Pragma: no-cache`
and `Connection: close`.

The parser accepts one HTTP/1.1 bodyless GET (absent or zero Content-Length),
or POST with a positive decimal Content-Length and `application/json`, with a
4096-byte header cap and 32768-byte body cap. The body
bound accommodates escaped JSON for the verifier's 4096-byte UTF-8 password
limit. It rejects duplicate/folded headers, ambiguous framing, Transfer-Encoding,
Expect, protocol upgrades, invalid header bytes and coalesced trailing requests.
It never serves a second request on a connection. Unknown paths and malformed
schemas fail without accessing desktop content.

There are at most eight admitted connections and one authentication operation
in flight; extra authentication work is rejected instead of accumulated in a
worker queue. A single watchdog closes expired connections after approximately
five seconds (100-ms checks). Worker verification itself is bounded to four
seconds. Failed sends/disconnected requests revoke newly issued tokens; stop
revokes all tokens after in-flight work. Completion clears mutable buffers and
breaks connection callback ownership cycles. Foundation/Network may retain
internal plaintext copies temporarily; complete framework-memory wiping is not
claimed. No raw request is persisted.

## Public discovery boundary

`server-information.m` builds the existing metadata-v1 XML contract with Apple's
XML serializer. Its immutable inputs are an operator-selected display name,
persisted workstation UUID and effective build version. The qualification
executable supplies a synthetic name/UUID/version, never the developer's machine
name or hardware identity. Persistent service state is still a future gate.
The advertised control port is the actual bound listener port, not a copied
default. There are no alternate address or port-discovery rules.

Discovery does not look up accounts or disclose UIDs, desktop geometry, tokens
or hardware serials. By default it does not disclose usernames either.
`[security] publish_session_user = true` permits a sanitized, cached OS desktop
login name as `PlankSessionUser`; the installer defaults this privacy-sensitive
option off. It is never an authentication identity and is absent at LoginWindow.
Unauthenticated `/serverinfo` includes a `PlankOccupied` bit: `1` for an Aqua user desktop or a
reserved/live stream, including a connection to LoginWindow; otherwise `0`.
Occupancy is a courtesy indicator only; it does not replace authentication or
block a locally logged-in user from connecting remotely. Query strings are
rejected, including retired `uniqueid`/`uuid` metadata. GET cannot invoke an
authentication route. Free/occupied discovery XML is cached at listener readiness
and selected using an atomic stream-lease snapshot. Polls neither occupy the
authentication queue nor run account lookup, token pruning or session teardown.

`PlankAuth=1` describes the implemented authentication conversation, not a
desktop grant. `ServerCodecModeSupport=0`, `PlankTopologyVersion=0` and
`PlankFeatureFlags=0` deliberately declare that media launch/topology are not
ready. Omitting the codec field would make the existing Client assume H.264.
Do not advertise Apple media or Linux display/takeover features before their
end-to-end implementation. The original Client's actual `NvHTTP`/`NvComputer`
parser accepts this response as online metadata with no codec capability and
rejects a mismatched advertised control port. This does not qualify streaming.

## Authenticated fixed capture description

The topology GET uses the existing Client's Bearer header. The parser rejects
duplicate Authorization headers; only the real accepted peer address and a
valid desktop-bound token authorize the provider. The adapter checks ownership
again after querying geometry and never returns it on an invalid/expired token.
No account identity is placed in the response. This shares the bounded serial
authentication lane rather than adding another worker/queue.

The native provider reads the current main display's actual pixel mode and
desktop point bounds, with a second consistency read, and maintains a generation
for observed geometry/mode changes. It does not configure a monitor, create a
display, read image pixels or grant input. The explicit fixed-capture extension
and Apple encoding tuple are documented in `protocol/output-topology.md`.
Public codec/readiness flags remain zero while stream integration is unfinished.

The shared fixed-capture fixture passes on both Mac and Client; the Client's
existing Linux topology cases also pass. The live Aqua HTTPS test now reads
authorized actual geometry, verifies stable repeated metadata and rejects an
unknown token. Synthetic TLS tests reject unauthenticated geometry. These are
not capture/decoder, logout/fast-switch race or full-stream tests.

## Desktop authority

`apps/host/macos/auth/graphical-authority.m`, explicitly selecting the desktop role
in the HTTPS probe, runs in the graphical user's Aqua context.
It requires agreement between Security session graphic access, CoreGraphics
console/login-complete state, the process UID, SystemConfiguration's console
user and membership UUID. An SSH invocation correctly receives no authority.

Each authority gets a random, nonzero lifetime generation. Every snapshot checks
the live OS state. A 250-ms watchdog and session-resignation/sleep notifications
provide additional revocation. Screen saver and lock notifications do not revoke
an otherwise unchanged console session. The authenticated connection may show
the OS lock screen; macOS still requires its normal unlock credentials. Unlock
notifications cannot grant or reactivate authority. Once revoked or once identity diverges,
the object never re-arms: replacement requires a fresh agent and authentication.

This is a desktop-preview boundary, not the final machine-service/graphical-agent
authorization IPC. It does not log into macOS, unlock the screen, grant
LoginWindow access or complete continuous stream revocation. Lock/unlock,
fast-user switching, logout/relogin races and graphical-agent replacement still
need lifecycle qualification before product acceptance. Existing session-handoff
probe results do not automatically qualify this new integration.

## Qualification

Build with `scripts/test/build-macos-control.sh` as documented in the macOS build
runbook. It also runs the previous authentication tests. Current gates pass:

- 215 framing assertions, including every truncated prefix of valid GET/POST requests;
- escaped XML, immutable metadata, exact public-field allowlist, query validation,
  and the shared `tests/protocol/macos-server-information.xml` fixture;
- 93 authentication/stream-lease assertions, including individual-token revocation;
- TLS 1.3 authentication, rejection of TLS 1.2/plaintext/untrusted certificates,
  replay and malformed requests, slow-request expiry, eight-connection admission
  and recovery afterward, using a synthetic verifier only;
- real account verification through the isolated helper over loopback TLS in
  the actual Aqua context, with live owner matching and replay denial;
- actual Aqua authority present, explicit revocation latched, and SSH denied.

On linux-client-builder, the separate `tests/protocol/macos-client-discovery.pro` harness
compiles the unchanged Client parser from its exact clean worktree against that
same fixture. Qt 6.10.2 passes online identity/version parsing, explicit zero
capabilities and wrong-port rejection. It does not open a connection or install
an application, and is not a full Client integration/decoder qualification.

The qualification executable binds only `127.0.0.1` on an ephemeral port and
expires after 60 seconds. The runner removes its own temporary job, certificates,
keys and output files. The fixtures have the product's RSA-3072/SHA-256,
self-signed CA and DNS-only SAN shape; none enters the keychain/trust store.
The test client trusts the exact generated fixture through the OS OpenSSL CLI.
It is not the PLANK Client and does not qualify the Client's certificate-approval
UI, hostname policy or native QUIC launch.

## Next integration gate

The Client now has an explicit per-bookmark ScreenCaptureKit/VideoToolbox Main10
**4:2:0** preview profile and an actual Apple-encoded synthetic decoder fixture.
Existing Linux profile IDs and bitrate values remain intact. Its launch is
explicitly disabled: a bookmark/profile and decoder-format test do not establish
working native media. The shared color validator checks limited BT.709 and sRGB,
including storage metadata for hardware surfaces without downloading pixels.
This is not yet hardware decoder or presentation qualification.

The claim/lease, native-video adapter, typed launch and capture-owning coordinator
now pass component and short authenticated loopback tests; see
`macos-authentication.md` and `macos-native-video.md`.
Fixed capture now registers a process-lifetime CoreGraphics reconfiguration
observer. Every observed change invalidates generation, including a change back
to identical geometry between queries. Snapshots reject in-progress or mid-read
changes; callback registration failure fails construction. Synthetic CG tests
cover these cases without touching real displays. No new polling worker exists.
The coordinator compares generation while idle and before encoded submission.

Next connect the ordinary Client's fixed geometry and launch to this path, with
explicit optional audio/cursor/input handling. Do not label Apple output as NVENC, 4:4:4 or
RGB identity. Keep takeover, input ownership and cleanup gates explicit.
Persistent administrator configuration, protected TLS-key loading, packaged
signing and required LoginWindow lifecycle remain unfinished.
