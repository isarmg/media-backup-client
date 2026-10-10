#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

fail() {
    echo "mobile ABI v1 contract gate: $*" >&2
    exit 1
}

test ! -e crates/mobile-ffi/include/xszc.h \
    || fail "the unversioned C header still exists"
test -f crates/mobile-ffi/include/xszc_ffi_v1.h \
    || fail "the current ABI 1 C header is missing"
test ! -e crates/mobile-ffi/include/xszc_v0_2_r1.h \
    || fail "the removed NUL-string C ABI header remains"
if rg -n 'xszc_v0_2_r1|NativeBridgeV02|withCString|@_silgen_name' crates/mobile-ffi/src clients/ios/Xszc/RustClient.swift clients/android/app/src/main; then
    fail "a removed mobile ABI implementation or caller remains"
fi
python3 scripts/check-mobile-header.py
for required_ios_property in \
    'NSPhotoLibraryUsageDescription:' \
    'NSPhotoLibraryAddUsageDescription:' \
    'BGTaskSchedulerPermittedIdentifiers:'; do
    grep -q -F "$required_ios_property" clients/ios/project.yml \
        || fail "the generated iOS Info.plist contract is missing: $required_ios_property"
done

if grep -R -I -n -E 'Java_org_sarmg_xszc_NativeBridge_|native(Open|Close|Needs|Enqueue|Next|MarkUpload|MarkPart|MarkComplete|MarkFailed|Stats)([^[:alnum:]_]|$)' \
    crates/mobile-ffi/src clients/ios/Xszc clients/android/app/src/main; then
    fail "a non-current unversioned native ABI entry point remains"
fi

if grep -R -I -n -E 'com[.]example|Java_com_example_' \
    crates/mobile-ffi/src clients/android/app/src clients/android/app/build.gradle.kts clients/ios; then
    fail "a development placeholder application identity remains"
fi

for required in \
    'xszc-mobile-v1' \
    'client-v1.sqlite' \
    'backup-staging-v1' \
    'xszc_open_v1' \
    'Java_org_sarmg_xszc_NativeBridgeV1_open' \
    'org.sarmg.xszc'; do
    # All platform clients live below clients/; keeping this gate on the
    # canonical paths makes directory drift fail visibly in CI.
    grep -R -I -q -F "$required" crates/mobile-ffi crates/client-core clients/android clients/ios \
        || fail "required mobile ABI v1 contract marker is missing: $required"
done

grep -q -F 'XSZC_ANDROID_SIGNING_PKCS12_BASE64' .github/workflows/release.yml \
    || fail "the formal Android release does not require the current PKCS#12 Secret"
grep -q -F '0cfc2811d48cdeab3e6d857029d879e001ab9531c06784b4d48d15a847771421' \
    .github/workflows/release.yml \
    || fail "the formal Android release does not pin the current certificate fingerprint"
grep -q -F 'assembleRelease' .github/workflows/release.yml \
    || fail "the formal Android release is not a signed release APK build"
python3 scripts/check-signing-secret-references.py .github/workflows/release.yml
if grep -q -E 'assembleDebug|app-debug[.]apk' .github/workflows/release.yml; then
    fail "the formal release workflow still contains a debug Android signing path"
fi

for workflow in .github/workflows/build.yml .github/workflows/release.yml; do
    grep -q -F 'bash scripts/verify-ios-toolchain.sh' "$workflow" \
        || fail "$workflow must verify Xcode 26 and iOS 26 SDKs"
    grep -q -F 'python3 scripts/package-ios-ipa.py' "$workflow" \
        || fail "$workflow must package the device app as an IPA"
    grep -q -F 'path: dist/*.ipa' "$workflow" \
        || fail "$workflow must upload the IPA artifact"
done
grep -q -F 'iOS: "26.0"' clients/ios/project.yml \
    || fail "the iOS application and tests must require iOS 26.0"
grep -q -F 'export IPHONEOS_DEPLOYMENT_TARGET=26.0' scripts/build-ios-rust.sh \
    || fail "the Rust iOS slices must require iOS 26.0"
if grep -q -F 'unsigned.tar.gz' .github/workflows/release.yml; then
    fail "iOS releases must publish IPA files rather than app tarballs"
fi

echo "mobile ABI v1 and state-epoch static gate passed"
