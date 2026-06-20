#!/usr/bin/env pwsh
# Idiomatic-Rust verification gate. Run from a crate/workspace root.
# Stops on the first failing stage so the agent must fix, not skip.
$ErrorActionPreference = 'Stop'

Write-Host '==> cargo fmt --check'
cargo fmt --all -- --check
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host '==> cargo clippy --all-targets --all-features -- -D warnings'
cargo clippy --all-targets --all-features -- -D warnings
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host '==> cargo test'
cargo test --all-features
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host 'All checks passed.'
