# Error Handling

Idiomatic Rust error handling: model fallibility in the type system and reserve panics for bugs.

## Model absence and failure in types, never with sentinels

`Option<T>` and `Result<T, E>` are distinct from `T`, so the compiler forces the caller to confront the missing/failed case before touching the inner value. Sentinel values (`-1`, `0`, a global errno) silently leak into normal code paths and reintroduce the null-pointer class of bugs Rust was built to eliminate. `Result` also carries `#[must_use]`, so discarding one is a compiler warning.

```rust
// Idiomatic
fn find_user(name: &str) -> Result<UserId, io::Error> { /* ... */ }
let absent: Option<i32> = None;

// Avoid
fn find_user(name: &str) -> UserId { /* returns -1 on failure */ }
let absent: i32 = -1; // "means" not found
```

Never silently discard a `Result` — that is what the `#[must_use]` lint guards against. Note the distinction: `.expect("…")` does not *drop* the error, it *panics loudly* with your message, which is an acceptable prototyping placeholder; silently dropping is `let _ = result;` or `.ok()`-and-ignore. In production, propagate with `?` or handle it, rather than either panicking or dropping.

Distinguish the two carriers by *meaning*, not convenience. `Option::None` means "nothing to return"; it does not mean "an operation failed". For a fallible operation that carries no error payload, return `Result<T, E>` with a dedicated unit-struct error (which implements `Error`) rather than `Option<T>` — you keep `#[must_use]` semantics and signal that both outcomes matter. Note `()` does not implement `Error`, so define a real type.

```rust
// Idiomatic
#[derive(Debug)] struct ParseFailed;
impl std::error::Error for ParseFailed {}
fn try_parse(s: &str) -> Result<Parsed, ParseFailed> { /* ... */ }

// Avoid: None conflates "failure" with "empty"
fn try_parse(s: &str) -> Option<Parsed> { /* ... */ }
```

When an operation can both fail *and* legitimately produce no value, nest them as `Result<Option<T>, E>` so callers handle each axis independently — collapsing them loses the difference between "not found" and "the disk errored".

```rust
fn get(&self, key: &Key) -> io::Result<Option<Value>> {
    let pos = match self.index.get(key) {
        None => return Ok(None),     // legitimately absent
        Some(p) => *p,
    };
    Ok(Some(self.read_at(pos)?))     // I/O failure propagates as Err
}
```

## Choose panic vs. Result by who is at fault

- **Recoverable / expected failure** (file not found, malformed input, division by zero) → return `Result`. The library cannot know how the caller wants to react, so keep the choice with them.
- **Contract / invariant violation** (a caller passed contradictory inputs, an index is out of bounds, an internal assumption broke) → `panic!` / `assert!`. These are bugs in calling code that cannot be sanely recovered from at runtime.

Never use `panic!` as a recoverable error path — unwinding is expensive, its cost model is tuned for the no-panic case, and a panic mid-operation can leave data structures inconsistent.

```rust
// Idiomatic
fn parse_config(s: &str) -> Result<Config, ParseError> { /* ... */ }
fn get(&self, i: usize) -> &T {
    assert!(i < self.len, "index out of bounds"); // caller bug
    /* ... */
}

// Avoid
fn divide(a: f64, b: f64) -> f64 {
    if b == 0.0 { panic!("division by zero"); } // expected, recoverable case
    a / b
}
```

Library code in particular should return `Result` rather than calling `panic!`/`unwrap`/`expect`, since it cannot make recovery decisions for its consumers. Prefer `Result` over global error codes (C-style errno) or `bool`: a `bool` carries no detail and an out-of-band errno is unenforced and easily forgotten. The same applies when calling fallible OS APIs — return `Result` rather than firing the call and inspecting `io::Error::last_os_error()` afterward; that "cheat" sacrifices type safety.

## Validate untrusted input before indexing or converting

Slicing into attacker-controlled bytes without a length check panics with an opaque index-out-of-bounds — a denial-of-service vector on network input. Guard fixed-size structures (crypto keys, signatures, headers) with an early `return Err(...)`, then use `TryFrom`/`try_from` for the fallible conversion so a malformed value propagates through `?` instead of crashing the process.

```rust
// Idiomatic
if sig_bytes.len() != ED25519_SIGNATURE_SIZE {
    return Err(Error::Internal("signature size not valid".into()));
}
let sig = ed25519_dalek::Signature::try_from(&sig_bytes[0..64])?;

// Avoid: panics or misleads on short/hostile input
let sig = ed25519_dalek::Signature::from_bytes(&sig_bytes[0..64]).unwrap();
```

## Pair panicking entrypoints with fallible variants

The buck stops somewhere: code that owns `main`, tests, and examples can legitimately `unwrap`. For public APIs, expose both a fallible and an infallible form so callers pick the contract they want — mirroring `String::from_utf8` / `from_utf8_unchecked`, or `ThreadPool::build` / `new`.

```rust
pub fn parse(s: &str) -> Result<MyType, ParseError> { /* ... */ }
pub fn parse_unchecked(s: &str) -> MyType { parse(s).expect("invalid input") }

pub fn new(size: usize) -> ThreadPool {
    assert!(size > 0); // misuse → panic
    ThreadPool { /* ... */ }
}
pub fn build(size: usize) -> Result<ThreadPool, PoolCreationError> {
    if size == 0 { return Err(PoolCreationError); }
    Ok(ThreadPool { /* ... */ })
}
```

Where you genuinely can't propagate — proc-macro `derive` functions must return `TokenStream`, not `Result` — prefer `expect("descriptive message")` over bare `unwrap` so the user's build shows a diagnostic instead of an opaque thread panic.

## Prefer `expect` over `unwrap`; describe the invariant

Both panic on the bad variant, but `expect`'s message documents *why* you believe the value is present, turning a future panic into an immediate diagnosis. Reserve either for exploratory code or for invariants provably impossible to violate — and document the reasoning where it isn't obvious. `unwrap` in a production path silently tears down the process (or a tokio task), bypassing structured reporting.

```rust
// Idiomatic — message states the invariant
File::open("hello.txt").expect("hello.txt is bundled with this crate");
let addr = addrs.first()
    .expect("non-empty: guaranteed after to_socket_addrs succeeds");

// Avoid
File::open("hello.txt").unwrap();      // no context when it fires
let port = env::var("PORT").unwrap();  // silent panic if unset in prod
```

## Propagate with `?` instead of match boilerplate

`?` early-returns on `Err`/`None` and applies a `From` conversion on the error — the same logic as a verbose `match`, in one character. Chain it to collapse multi-step pipelines and keep the happy path obvious.

```rust
// Idiomatic
fn read_username() -> Result<String, io::Error> {
    let mut s = String::new();
    File::open("hello.txt")?.read_to_string(&mut s)?;
    Ok(s)
}

// Avoid
let mut file = match File::open("hello.txt") {
    Ok(f) => f,
    Err(e) => return Err(e),
};
```

`?` does not convert between `Result` and `Option`. Bridge them explicitly: `.ok()` turns a `Result` into an `Option`; `.ok_or(err)` / `.ok_or_else(|| …)` turn an `Option` into a `Result`.

```rust
let val = maybe.ok_or(MyError::Missing)?; // Option -> Result, then propagate
```

To use `?` at the top level, give `main` a `Result` return type; `Ok` maps to exit code 0, `Err` to non-zero.

```rust
fn main() -> Result<(), Box<dyn Error>> {
    let _f = File::open("hello.txt")?;
    Ok(())
}
```

## Match a specific error variant; propagate the rest

When you filter one expected error (e.g. "not found" becomes `None`), re-raise everything else with `Err(err) => Err(err)`. Collapsing to `.ok()` or a catch-all swallows connection failures, deserialization bugs, and any variant added later — silent misbehavior that surfaces far from its cause. The same discipline applies to `io::ErrorKind`: match the exact kind you treat as normal and return the rest.

```rust
// Idiomatic — expected absence vs. unexpected failure stay distinct
match repo.find_job(id).await {
    Ok(job) => Ok(Some(job)),
    Err(Error::NotFound(_)) => Ok(None), // expected
    Err(err) => Err(err),                // unexpected: propagate
}

// Idiomatic — EOF is a normal loop exit, other I/O errors are not
loop {
    let kv = match process_record(&mut f) {
        Ok(kv) => kv,
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => break,
        Err(e) => return Err(e),
    };
    index.insert(kv.key, pos);
}

// Avoid: hides real failures behind "not found"
repo.find_job(id).await.ok();
```

Likewise, match transport status codes into distinct typed variants rather than collapsing every non-success into one generic error — callers need the distinction to retry a 500 but redirect on a 401.

```rust
match resp.status().as_u16() {
    401 => Err(Error::Unauthorized),
    404 => Err(Error::NotFound),
    500 => Err(Error::InternalServerError),
    _   => Err(Error::Request),
}
```

## Try independent strategies with `if let Ok(_)`

When several fallible approaches should each be attempted in priority order — installing persistence, locating a config, picking a backend — `?` is wrong: it aborts on the first failure. Chain `if let Ok(_) = strategy() { return Ok(()); }` so each alternative is tried until one succeeds. The same `if let Ok(v) = expr` shape also unwraps-and-binds inline when an error case should simply be skipped, avoiding a full `match`.

```rust
// Try each, succeed on the first that works
if let Ok(_) = install_systemd(&path) { return Ok(()); }
if let Ok(_) = install_crontab(&path) { return Ok(()); }
Ok(())

// Skip malformed rows instead of panicking
if let Ok(len) = fields[1].parse::<f32>() { println!("{name}, {len}cm"); }
```

## Prefer combinators over manual `match`

`.map`, `.and_then`, `.map_err`, `.map_or`, `.unwrap_or`, `.ok_or`, `.as_ref`, etc. state intent more concisely than match arms, are `#[inline]` (no runtime cost), and compose with `?`. Transform the error type at the point where you have context.

```rust
// Idiomatic
let f = File::open("/etc/passwd").map_err(|e| format!("open failed: {e:?}"))?;
let ignore_case = env::var("IGNORE_CASE").is_ok(); // presence only
let port = env::var("PORT").map_or(Ok(8080), |v| v.parse::<u16>())?; // default + parse

// Avoid
let f = match File::open("/etc/passwd") {
    Ok(f) => f,
    Err(e) => return Err(format!("open failed: {e:?}")),
};
```

Enum tuple variants are constructor functions, so `.map_err(MyError::Io)` is shorthand for `.map_err(|e| MyError::Io(e))` — useful before you implement `From` (below).

Use `.as_ref()` to go from `&Option<T>` to `Option<&T>` before a consuming method when the value sits behind a shared reference, otherwise the borrow checker rejects the move:

```rust
fn encrypted(&self) -> Vec<u8> {
    encrypt(self.payload.as_ref().unwrap_or(&vec![])) // no move out of &self
}
```

## Build custom error types and let `?` convert them

Implement `std::error::Error` (which requires `Debug` + `Display`) so your type composes with the ecosystem — trait-object wrapping, `anyhow`, and the `source()` chain all rely on it. Then implement `From<SubError>` (never `Into`) for each underlying error so `?` converts automatically with no `.map_err()` at every call site. In application (not library) code, prefer `anyhow` and attach human context as errors bubble up with `anyhow::Context` — `fs::read(&p).with_context(|| format!("reading config {p:?}"))?` — so the report names *which operation* failed, not just the low-level cause. Use `.with_context(|| …)` (lazy, allocates only on error) for formatted messages and `.context("…")` for static ones.

Implement `From`, not `Into`: the blanket `impl<T: From<U>> Into<U> for T` derives `Into` for free, and `?` invokes `From` internally — a type that only implements `Into` silently fails to work with `?`. If a richer `Display` isn't warranted yet, delegate to `Debug` (`write!(f, "{self:?}")`) so the `Error` impl compiles, and refine later.

```rust
#[derive(Debug)]
pub enum MyError { Io(io::Error) }

impl std::fmt::Display for MyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self { MyError::Io(e) => write!(f, "io: {e}") }
    }
}
impl std::error::Error for MyError {}

impl From<io::Error> for MyError {        // NOT impl Into<MyError> for io::Error
    fn from(e: io::Error) -> Self { MyError::Io(e) }
}

fn load() -> Result<String, MyError> {
    let s = fs::read_to_string("x")?; // io::Error -> MyError automatically
    Ok(s)
}
```

**Make error types `Send + Sync + 'static`.** Errors that aren't `Send + Sync` can't cross thread boundaries, can't be wrapped by `std::io::Error`, and can't be type-erased into `Box<dyn Error + Send + Sync>`; the `'static` bound additionally enables `Error::downcast_ref`. So store owned, thread-safe data (`String`, owned values) — never `Rc`, `RefCell`, or borrowed data — in error fields.

```rust
// Idiomatic — String is Send + Sync + 'static
pub struct MyError { message: String }

// Avoid — Rc is neither Send nor Sync
pub struct MyError { context: Rc<String> }
```

**Use the right crate for the job:** `thiserror` generates the `Display`/`Error`/`From` boilerplate for **library** error enums without leaking its own types into your public API. `anyhow` provides a dynamic `anyhow::Error` (with backtraces) for **application** code where many library error types must coexist. `Box<dyn Error>` is the std-only equivalent — acceptable in a binary's `main` where the error is only printed, but never in library code: it erases the concrete type so callers can't match on variants.

## Grow the error enum organically and convert at the boundary

Start a new project with a minimal error enum that includes an `Internal(String)` catch-all, then add variants as you actually hit them — guessing thirty variants upfront produces a worse taxonomy than letting the domain reveal them. Crucially, convert upstream errors (database, HTTP client) into your domain error *at their source layer*, e.g. inside the repository method, so service and presentation layers never see `sqlx::Error` and you have a single place to log the translation.

```rust
#[derive(thiserror::Error, Debug, Clone)]
pub enum Error {
    #[error("not found")]
    NotFound(String),
    #[error("internal error")]
    Internal(String), // escape hatch; specialize later
}

// In the repository method, at the source of the error:
.map_err(|e| { error!("create_job: {e}"); Error::Internal(e.to_string()) })?
```

## CLI exit and diagnostics

Translate errors into clean exits at the top, not panic noise. Send diagnostics to **stderr** with `eprintln!` so they survive when the user redirects stdout to a file.

```rust
// success value matters:
let config = Config::build(&args).unwrap_or_else(|err| {
    eprintln!("Problem parsing arguments: {err}");
    process::exit(1);
});

// success value is (): only the error path matters
if let Err(e) = run(config) {
    eprintln!("Application error: {e}");
    process::exit(1);
}
```

## Make integer-overflow behavior explicit

Debug builds panic on overflow; release builds silently wrap (two's complement). Relying on either is a latent bug. State the intent with `checked_*` (→ `Option`), `wrapping_*`, `saturating_*`, or `overflowing_*`.

```rust
// Idiomatic
let safe = a.checked_add(b);   // None on overflow
let wrap = a.wrapping_add(b);  // intentional wrap

// Avoid
let r = a + b; // panics in debug, silently wraps in release
```

## Do not use `catch_unwind` as exceptions

`catch_unwind` is not a general exception mechanism: panics may *abort* rather than unwind depending on compiler flags or target (e.g. WebAssembly), and catching one mid-operation can expose inconsistent state. Its only legitimate use is stopping panics from crossing an FFI boundary.

```rust
// Legitimate: FFI boundary only
let result = std::panic::catch_unwind(|| rust_fn());

// Avoid: treating a panic as a recoverable error
match std::panic::catch_unwind(|| divide(a, b)) {
    Ok(x) => x,
    Err(_) => default,
}
```
