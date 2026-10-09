#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
check_dir=$(mktemp -d /tmp/photoslim-checks.XXXXXX)
trap 'rm -rf "$check_dir"' EXIT HUP INT TERM
swiftc -D SAFETY_CHECKS PhotoSlim/SlimRun.swift PhotoSlim/StorageSafety.swift slim_run_check.swift -o "$check_dir/recovery"
"$check_dir/recovery"
swiftc PhotoSlim/Models.swift PhotoSlim/PhotoEncoder.swift metadata_check.swift -o "$check_dir/encoder"
"$check_dir/encoder"
swiftc PhotoSlim/MediaSafety.swift PhotoSlim/MediaFingerprint.swift fingerprint_check.swift -o "$check_dir/fingerprint"
"$check_dir/fingerprint"
