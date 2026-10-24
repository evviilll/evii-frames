#!/usr/bin/env bash
# Capture the screenshot fixtures. Usage: ci/screenshots.sh <app> <output-dir>
set -euo pipefail

APP="${1:?path to EviiFrames.app}"
OUT="${2:?output directory}"
mkdir -p "${OUT}"

UDID="$(python3 - << 'PY'
import json, subprocess
raw = subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"])
data = json.loads(raw)
chosen = None
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    for device in devices:
        name = device.get("name", "")
        if not device.get("isAvailable") or "iPhone" not in name:
            continue
        rank = (1 if "Pro" not in name else 0, name)
        if chosen is None or rank > chosen[0]:
            chosen = (rank, device["udid"], name)
if not chosen:
    raise SystemExit("no iPhone simulator")
print(chosen[1])
PY
)"

echo "simulator ${UDID}"
xcrun simctl boot "${UDID}" || true
xcrun simctl bootstatus "${UDID}" -b
xcrun simctl ui "${UDID}" appearance dark
xcrun simctl status_bar "${UDID}" override \
  --time "9:41" \
  --batteryState charged \
  --batteryLevel 100 \
  --cellularMode active \
  --cellularBars 4 \
  --wifiBars 3 \
  --operatorName "" || true

xcrun simctl install "${UDID}" "${APP}"

SCREENS=(home interpolation interp-settings export slowmo processing done queue settings)
for name in "${SCREENS[@]}"; do
  xcrun simctl terminate "${UDID}" com.evii.frames >/dev/null 2>&1 || true
  xcrun simctl launch "${UDID}" com.evii.frames -eviiScreenshot "${name}"
  sleep 4
  xcrun simctl io "${UDID}" screenshot "${OUT}/${name}.png"
  echo "saved ${name}.png"
done
