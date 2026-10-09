#!/usr/bin/env bash
set -euo pipefail
simulator_udid="$1"
# Use deterministic generated photos; no personal media enters test artifacts.
fixture_dir="${RUNNER_TEMP:?}/xszc-layout-photos"
mkdir -p "$fixture_dir"
python3 - "$fixture_dir" <<'PY'
from pathlib import Path
import struct, sys, zlib
root = Path(sys.argv[1])
def chunk(kind, data):
    return struct.pack('>I', len(data)) + kind + data + struct.pack('>I', zlib.crc32(kind + data))
for index in range(1, 9):
    color = [(62, 126, 160), (196, 139, 74), (86, 143, 112)][(index - 1) % 3]
    rows = b''.join(b'\0' + bytes(min(255, c + y // 5) for _ in range(320) for c in color) for y in range(240))
    png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', 320, 240, 8, 2, 0, 0, 0))
    png += chunk(b'IDAT', zlib.compress(rows)) + chunk(b'IEND', b'')
    (root / f'layout-photo-{index}.png').write_bytes(png)
PY
if ! xcrun simctl list devices booted -j | python3 -c 'import json,sys; target=sys.argv[1]; sys.exit(not any(d["udid"] == target for devices in json.load(sys.stdin)["devices"].values() for d in devices))' "$simulator_udid"; then
  xcrun simctl boot "$simulator_udid"
fi
xcrun simctl bootstatus "$simulator_udid" -b
# Insert photo 1 last so the named selection fixture remains in the first visible rows.
for ((index=8; index>=1; index--)); do
  xcrun simctl addmedia "$simulator_udid" "$fixture_dir/layout-photo-$index.png"
done
# Unit tests launch the host app first, and XCTest can deny its startup prompt.
# Reset that prior decision so UI tests exercise the real first-use prompt.
# Do not pre-grant permission: the UI test must tap Allow Full Access itself.
if xcrun simctl get_app_container "$simulator_udid" org.sarmg.xszc app >/dev/null 2>&1; then
  xcrun simctl privacy "$simulator_udid" reset photos org.sarmg.xszc
fi
