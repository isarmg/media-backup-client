#!/usr/bin/env bash
set -euo pipefail

# A fresh, dedicated CI AVD; never targets a connected physical device.
sdk_root="${ANDROID_HOME:?Android SDK required}"
avd_name="media-backup-api36-${GITHUB_RUN_ID:?CI run ID required}-${GITHUB_RUN_ATTEMPT:-1}"
# New SDK tools and emulator releases can choose different default AVD homes.
# Pin both to this run's isolated directory; do not repurpose the user's HOME.
avd_storage="$(mktemp -d "${RUNNER_TEMP:?}/media-backup-avd.XXXXXX")"
export ANDROID_USER_HOME="$avd_storage"
export ANDROID_AVD_HOME="$avd_storage/avd"
mkdir -p "$ANDROID_AVD_HOME"
serial=emulator-5554
emulator_pid=""
cleanup() {
  if [[ -n "$emulator_pid" ]]; then
    "$sdk_root/platform-tools/adb" -s "$serial" emu kill || true
    kill "$emulator_pid" 2>/dev/null || true
    wait "$emulator_pid" 2>/dev/null || true
  fi
  avdmanager delete avd -n "$avd_name" || true
}
trap cleanup EXIT
test -r /dev/kvm && test -w /dev/kvm
printf 'no\n' | avdmanager create avd -n "$avd_name" -k 'system-images;android-36;google_apis;x86_64'
test -f "$ANDROID_AVD_HOME/$avd_name.ini"
"$sdk_root/emulator/emulator" -list-avds | grep -Fx "$avd_name"
"$sdk_root/emulator/emulator" -avd "$avd_name" -port 5554 -no-window -no-audio \
  -no-boot-anim -no-snapshot -gpu swiftshader_indirect >"${RUNNER_TEMP:?}/media-backup-emulator.log" 2>&1 &
emulator_pid=$!
booted=false
for ((attempt=0; attempt<120; attempt++)); do
  kill -0 "$emulator_pid" 2>/dev/null || { tail -100 "$RUNNER_TEMP/media-backup-emulator.log"; exit 1; }
  if [[ "$("$sdk_root/platform-tools/adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then
    booted=true
    break
  fi
  sleep 3
done
test "$booted" = true
test "$("$sdk_root/platform-tools/adb" -s "$serial" shell getprop ro.build.version.sdk | tr -d '\r')" = 36
ANDROID_SERIAL="$serial" gradle -p clients/android -PmediaBackupEmulatorTests=true connectedDebugAndroidTest
