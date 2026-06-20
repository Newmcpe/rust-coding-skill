#!/usr/bin/env bash
# Idiomatic-Rust verification gate. Run from a crate/workspace root.
# Exits non-zero on the first failing stage so the agent must fix, not skip.
set -euo pipefail

echo "==> cargo fmt --check"
cargo fmt --all -- --check

echo "==> cargo clippy --all-targets --all-features -- -D warnings"
cargo clippy --all-targets --all-features -- -D warnings

echo "==> cargo test"
cargo test --all-features

echo "All checks passed."
