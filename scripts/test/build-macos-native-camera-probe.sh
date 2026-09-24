#!/bin/bash
# Build only. Never installs, activates, opens cameras or changes permissions.
set -euo pipefail
if [[ $# != 3 || $1 != /* || $2 != /* || ( $3 != --unsigned && $3 != --sign ) ]]; then
    echo "Usage: $0 /absolute/source /new/output --unsigned|--sign" >&2; exit 2
fi
if [[ $(uname -s) != Darwin || $(uname -m) != arm64 ||
      $(sw_vers -productVersion | cut -d . -f 1) -lt 27 ||
      $(xcrun --sdk macosx --show-sdk-version | cut -d . -f 1) -lt 27 ]]; then
    echo "Requires the authorized Apple Silicon macOS 27/SDK 27 development Mac." >&2; exit 2
fi
if [[ ! ${PLANK_MACOS_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]]; then
    echo "Set PLANK_MACOS_TEAM_ID to the authorized signing team." >&2; exit 2
fi
if [[ $3 == --sign && ! ${PLANK_MACOS_SIGNING_IDENTITY:-} =~ ^[A-Fa-f0-9]{40}$ ]]; then
    echo "Set PLANK_MACOS_SIGNING_IDENTITY to a usable certificate identity SHA-1." >&2; exit 2
fi
if [[ $3 == --sign && ( ${PLANK_MACOS_APP_PROVISION_PROFILE:-} != /* ||
                        ! -f ${PLANK_MACOS_APP_PROVISION_PROFILE:-} ) ]]; then
    echo "Set PLANK_MACOS_APP_PROVISION_PROFILE to the authorized Developer ID profile for this probe." >&2
    echo "A certificate alone does not authorize the system-extension.install entitlement." >&2
    exit 2
fi
source_root=$1
output=$2
mode=$3
mkdir "$output"
cd "$source_root"
shasum -a 256 probes/macos/native-camera-{extension.m,consumer.m,fixture.h,fixture.m} \
    scripts/test/build-macos-native-camera-probe.sh
app="$output/PLANK Native Camera Probe.app"
extension="$app/Contents/Library/SystemExtensions/la.instinctual.PLANK.NativeCameraProbe.Camera.systemextension"
mkdir -p "$app/Contents/MacOS" "$extension/Contents/MacOS"
python3 - "$app" "$extension" "$PLANK_MACOS_TEAM_ID" "$output" <<'PY'
from pathlib import Path
import plistlib, sys
app, extension, team, output = sys.argv[1:]
app_id = 'la.instinctual.PLANK.NativeCameraProbe'
extension_id = app_id + '.Camera'
group = team + '.' + app_id
common = dict(CFBundleVersion='1', CFBundleShortVersionString='1.0', LSMinimumSystemVersion='27.0')
def write(path, value):
    Path(path).write_bytes(plistlib.dumps(value))
write(Path(app)/'Contents/Info.plist', dict(common, CFBundleIdentifier=app_id,
    CFBundleExecutable='native-camera-consumer', CFBundlePackageType='APPL',
    CFBundleName='PLANK Native Camera Probe', LSUIElement=True,
    NSCameraUsageDescription='Inspect only the PLANK synthetic test camera to qualify native H.264 and decoded pixels.',
    NSSystemExtensionUsageDescription='Temporarily provide a synthetic H.264/NV12 camera for PLANK format qualification.'))
write(Path(extension)/'Contents/Info.plist', dict(common, CFBundleIdentifier=extension_id,
    CFBundleExecutable='native-camera-extension', CFBundlePackageType='SYSX',
    CFBundleName='PLANK Synthetic Native Camera',
    NSSystemExtensionUsageDescription='Temporarily provide a synthetic H.264/NV12 camera for PLANK format qualification.',
    CMIOExtension={'CMIOExtensionMachServiceName': group + '.Camera'}))
entitlements = {'com.apple.security.app-sandbox': True,
                'com.apple.security.application-groups': [group]}
write(Path(output)/'extension-entitlements.plist', entitlements)
write(Path(output)/'app-entitlements.plist', dict(entitlements,
    **{'com.apple.developer.system-extension.install': True,
       'com.apple.application-identifier': team + '.' + app_id,
       'com.apple.developer.team-identifier': team,
       'com.apple.security.device.camera': True}))
PY
if [[ $mode == --sign ]]; then
    # Check the selected profile before compiling or using the signing key.
    # Profile contents remain in the local output; never print account/device metadata.
    python3 - "$app" "$PLANK_MACOS_APP_PROVISION_PROFILE" \
        "$PLANK_MACOS_TEAM_ID" "$PLANK_MACOS_SIGNING_IDENTITY" <<'PY'
from datetime import datetime, timezone
from pathlib import Path
import hashlib, plistlib, subprocess, sys
app, profile, team, identity = sys.argv[1:]
data = Path(profile).read_bytes()
result = subprocess.run(['security', 'cms', '-D', '-i', profile], capture_output=True)
if result.returncode:
    sys.exit('Cannot decode the selected provisioning profile.')
value = plistlib.loads(result.stdout)
entitlements = value.get('Entitlements', {})
expected_id = team + '.la.instinctual.PLANK.NativeCameraProbe'
expiry = value.get('ExpirationDate')
valid = (entitlements.get('com.apple.application-identifier') == expected_id and
         entitlements.get('com.apple.developer.team-identifier') == team and
         entitlements.get('com.apple.developer.system-extension.install') is True and
         any(hashlib.sha1(cert).hexdigest().lower() == identity.lower()
             for cert in value.get('DeveloperCertificates', [])) and
         isinstance(expiry, datetime) and expiry.replace(tzinfo=timezone.utc) > datetime.now(timezone.utc))
if not valid:
    sys.exit('Profile does not authorize this probe, signing identity, team or current date.')
(Path(app)/'Contents/embedded.provisionprofile').write_bytes(data)
PY
fi
flags=(-std=c11 -O2 -g -mmacosx-version-min=27.0 -fobjc-arc -fblocks -Wall -Wextra -Werror)
frameworks=(-framework Foundation -framework CoreMedia -framework CoreVideo -framework VideoToolbox)
xcrun --sdk macosx clang "${flags[@]}" probes/macos/native-camera-extension.m \
    probes/macos/native-camera-fixture.m "${frameworks[@]}" -framework CoreMediaIO \
    -o "$extension/Contents/MacOS/native-camera-extension"
xcrun --sdk macosx clang "${flags[@]}" probes/macos/native-camera-consumer.m \
    probes/macos/native-camera-fixture.m "${frameworks[@]}" \
    -framework AppKit -framework AVFoundation -framework SystemExtensions \
    -o "$app/Contents/MacOS/native-camera-consumer"
plutil -lint "$app/Contents/Info.plist" "$extension/Contents/Info.plist" \
    "$output/app-entitlements.plist" "$output/extension-entitlements.plist"
if [[ $mode == --sign ]]; then
    codesign --force --sign "$PLANK_MACOS_SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements "$output/extension-entitlements.plist" "$extension"
    codesign --force --sign "$PLANK_MACOS_SIGNING_IDENTITY" --options runtime --timestamp \
        --entitlements "$output/app-entitlements.plist" "$app"
    codesign --verify --deep --strict "$app"
    echo "native_camera_probe_signed=yes notarization_tested=no activation_tested=no"
else
    echo "native_camera_probe_signed=no activation_tested=no"
fi
