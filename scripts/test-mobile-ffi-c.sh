#!/usr/bin/env bash
set -euo pipefail
ulimit -c 0
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
python3 scripts/check-mobile-header.py
CARGO_INCREMENTAL=0 cargo build --locked -p media-backup-mobile
target_dir="$(cargo metadata --locked --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["target_directory"])')"
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
cc -std=c17 -Wall -Wextra -Werror -I crates/mobile-ffi/include \
  crates/mobile-ffi/tests/abi.c -L "$target_dir/debug" -lmedia_backup_mobile \
  -Wl,-rpath,"$target_dir/debug" -o "$scratch/abi"
scratch="$(cd "$scratch" && pwd -P)"
if [[ "$(uname -s)" == Darwin ]]; then
  mkdir -m 700 "$scratch/container"
  cat > "$scratch/test.sb" <<EOF
(version 1)
(allow default)
(deny file-read* (literal "$scratch"))
EOF
  sandbox-exec -f "$scratch/test.sb" "$scratch/abi" "$scratch/container"
else
  "$scratch/abi" "$scratch"
fi
if [[ "$(uname -s)" == Darwin ]]; then
  symbols="$(nm -gU "$target_dir/debug/libmedia_backup_mobile.dylib")"
else
  symbols="$(nm -D --defined-only "$target_dir/debug/libmedia_backup_mobile.so")"
fi
if rg 'mb_v0_2_r1|sarmg_ffi_.*_v1|panicProbe' <<< "$symbols"; then
  echo "removed FFI symbols remain" >&2
  exit 1
fi
