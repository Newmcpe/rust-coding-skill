# Network & Security Tooling

Idiomatic Rust for building network and security tooling — scanners, probes, automation, monitors, and CLI utilities. Engineering craft only: concurrency, I/O, parsing, resilience, and packaging. Use within authorized engagements; respect scope, rate limits, and the law.

## Async I/O for network-bound work

Network tooling is I/O-bound: hundreds of connections spend their time waiting, not computing. Use async (`tokio`) so one thread drives many in-flight requests; do not spawn one OS thread per target.

```rust
// Idiomatic: bounded concurrency over many targets
use futures::stream::{self, StreamExt};

async fn probe_all(targets: Vec<Target>, limit: usize) -> Vec<Report> {
    stream::iter(targets)
        .map(|t| async move { probe(t).await })
        .buffer_unordered(limit) // cap in-flight work; do not unleash all at once
        .collect()
        .await
}

// Avoid: a thread per target exhausts the OS long before the network
// for t in targets { std::thread::spawn(move || blocking_probe(t)); }
```

Always bound concurrency (`buffer_unordered`, a `Semaphore`, or a worker pool). Unbounded fan-out is both a self-DoS and a footgun against the target's infrastructure.

## Timeouts, retries, and rate limits are non-optional

A scanner with no timeout hangs on the first black-holed host. Wrap every network call in a timeout, and make retry/backoff explicit.

```rust
use tokio::time::{timeout, Duration};

let resp = timeout(Duration::from_secs(5), client.get(url).send()).await;
match resp {
    Err(_elapsed) => Report::Timeout,        // the timeout fired
    Ok(Err(e))    => Report::NetError(e),     // connection/TLS error
    Ok(Ok(r))     => Report::Ok(r.status()),
}
```

- Use a shared rate limiter (e.g. `governor`) to stay within agreed engagement limits.
- Backoff with jitter on retry; never tight-loop a failing endpoint.
- Reuse one `reqwest::Client` (it pools connections); constructing a client per request defeats keep-alive and TLS-session reuse.

## Model results as data, not strings

Scan output is consumed by other tools. Model results with enums/structs and serialize with `serde`, so output is machine-parseable and invalid states are unrepresentable.

```rust
#[derive(serde::Serialize)]
#[serde(tag = "state", rename_all = "snake_case")]
enum PortState {
    Open { service: Option<String> },
    Closed,
    Filtered,
}
```

Emit JSON lines (`serde_json`) for piping into other tooling; offer a human table as a separate presentation layer. Keep the data model and its rendering apart.

## Parse untrusted input defensively

Tooling parses responses from systems you do not control. Never `unwrap` on parsed network data — a malformed or hostile response must become a handled error, not a panic that kills the scan.

```rust
// Idiomatic: structured parsing, fallible by construction
use nom::{IResult, bytes::complete::take};

fn parse_header(input: &[u8]) -> IResult<&[u8], Header> { /* ... */ }

// Avoid: indexing/slicing raw bytes — panics on short or crafted input
// let len = buf[4]; let body = &buf[5..5 + len as usize];
```

- Use `nom` / `winnow` for binary/protocol parsing; `serde` for structured text.
- Bound allocations from length fields: a 4-byte length claiming 4 GiB must be rejected, not `Vec::with_capacity`'d.
- Treat all lengths, offsets, and counts from the wire as adversarial.

## Errors: one type, propagate, never swallow

A long scan must not abort on the first error, nor hide it. Use a domain error enum, propagate per-task with `?`, and collect failures as results rather than crashing the run.

```rust
#[derive(thiserror::Error, Debug)]
enum ScanError {
    #[error("connect {0}")] Connect(#[from] std::io::Error),
    #[error("tls handshake failed")] Tls,
    #[error("protocol: {0}")] Protocol(String),
}
```

Use `thiserror` for a library/tool's own error type, `anyhow` only at the top-level binary. Per-target failures belong in the report (`Result<Report, ScanError>` per item), so one dead host never sinks the whole sweep.

## Secrets: keep them out of logs, argv, and core dumps

Tooling handles API tokens, credentials for authenticated scans, and session material. Treat them as sensitive by type.

- Read secrets from env or a file, **not** from CLI args (`ps`/shell history leak argv).
- Wrap them in `secrecy::SecretString` so they do not print via `Debug` and are zeroized on drop.
- Use `zeroize` for key material in buffers. Do not log request bodies/headers that may carry tokens.

```rust
use secrecy::{ExposeSecret, SecretString};

#[derive(Debug)] // SecretString prints as "[REDACTED]", safe to derive
struct Config { token: SecretString }

let auth = format!("Bearer {}", cfg.token.expose_secret()); // expose only at point of use
```

## TLS and crypto: use vetted crates, never roll your own

Use `rustls` (with `webpki-roots`) for TLS and `ring`/`RustCrypto` for primitives. Do not implement crypto or certificate validation by hand.

- Disabling certificate verification is sometimes needed against test targets — gate it behind an explicit `--insecure` flag and a loud warning, never the default.
- Prefer constant-time comparison (`subtle`) for any secret/MAC comparison; `==` on byte slices can leak via timing.

## Ergonomic, scriptable CLIs

These tools live in pipelines. Make them behave.

- Use `clap` (derive API) for argument parsing, help, and validation.
- Exit with meaningful codes (`std::process::ExitCode`): `0` success, non-zero per failure class, so scripts can branch.
- Support `--output json` for machine consumption and structured logging via `tracing` (with `tracing-subscriber`) gated by `-v/-vv`.
- Read large target lists from a file or stdin, not a giant argv.

```rust
#[derive(clap::Parser)]
struct Cli {
    #[arg(short, long, default_value_t = 100)] concurrency: usize,
    #[arg(long)] targets: std::path::PathBuf,
    #[arg(long, value_enum, default_value_t = OutFmt::Text)] output: OutFmt,
}
```

## Cross-compilation and lean static binaries

Tooling often must run on a host you do not control, with no toolchain. Ship a single static binary.

- Target `x86_64-unknown-linux-musl` for a fully static Linux binary (`cargo build --release --target ...`); use `cross` when the host toolchain is awkward.
- Shrink release binaries with `opt-level = "z"`, `lto = true`, `codegen-units = 1`, `strip = true`, and `panic = "abort"` in a release profile when size matters.
- Gate optional capabilities behind Cargo features so a minimal build stays small.

## Robust concurrency: cancellation and graceful shutdown

Long-running tools must stop cleanly on Ctrl-C — flushing partial results, not corrupting output.

- Listen for `tokio::signal::ctrl_c()` and propagate a `CancellationToken` (from `tokio-util`) to in-flight tasks.
- Drain and write buffered results on shutdown; do not leave a half-written report file.
- Bound channels (`tokio::sync::mpsc` with capacity) so a slow consumer applies backpressure instead of growing memory without limit.
