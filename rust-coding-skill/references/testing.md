# Testing in Rust

Write tests that compile out of release builds, diagnose their own failures, and run fast by default.

## Test placement and gating

Unit tests live in a `#[cfg(test)] mod tests` block in the **same file** as the code under test, and every test is annotated `#[test]`. `#[cfg(test)]` compiles the test code only during `cargo test`, so release binaries stay free of test code and normal `cargo build` stays fast. `#[test]` tells the runner which functions to invoke.

Because `tests` is a child module, bring the parent's items into scope with `use super::*;` — this also gives unit tests access to **private** items, which is their main advantage over integration tests.

```rust
// Idiomatic
#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn internal() {
        assert_eq!(4, internal_adder(2, 2)); // private fn, reachable here
    }
}

// Avoid
#[test] // no #[cfg(test)] — compiles into release builds, pollutes namespace
fn internal() { assert_eq!(4, internal_adder(2, 2)); }
```

Gate test-only accessors with `#[cfg(test)]` instead of permanently raising visibility. Making a field `pub(crate)` just to inspect it in a test leaks the internal to every module in the crate and invites accidental coupling; a `#[cfg(test)]` method exists only in the test build, so the production API stays clean.

```rust
// Idiomatic
impl RawTable {
    #[cfg(test)]
    pub(crate) fn buckets(&self) -> &[Bucket] { &self.buckets }
}

// Avoid
impl RawTable {
    pub(crate) fn buckets(&self) -> &[Bucket] { &self.buckets } // visible to all crate code, forever
}
```

## Assertions

Prefer `assert_eq!` / `assert_ne!` over `assert!(a == b)`. On failure they print **both operands**, so the test diagnoses itself; `assert!(a == b)` only reports "assertion failed" with no values.

Custom types compared this way must derive `PartialEq` (for `==`/`!=`) and `Debug` (to print on failure), or the test will not compile.

```rust
// Idiomatic
#[derive(PartialEq, Debug)]
struct Point { x: i32, y: i32 }

assert_eq!(Point { x: 1, y: 2 }, result);

// Avoid
assert!(result == Point { x: 1, y: 2 }); // no values on failure, and Point won't even compile here without the derives
```

For plain `assert!`, add a format-string message that prints the offending value — the default output gives only a line number, which is rarely enough to find the cause.

```rust
// Idiomatic
assert!(
    result.contains("Carol"),
    "Greeting did not contain name, value was `{result}`"
);

// Avoid
assert!(result.contains("Carol")); // failure shows nothing about `result`
```

Use `debug_assert!` / `debug_assert_eq!` for invariant checks that are expensive or only meaningful during development — they compile away entirely in `--release`, so they cost nothing in production while still catching logic errors in tests and debug builds.

```rust
// Idiomatic
debug_assert_eq!(data.len(), declared_len as usize); // free in release

// Avoid
assert_eq!(data.len(), declared_len as usize); // runs on every release call too
```

## Panics and error returns

Use `#[should_panic(expected = "...")]` with a substring of the panic message. Bare `#[should_panic]` passes for *any* panic, including one from an unrelated bug; the `expected` substring pins the failure to the intended code path.

```rust
// Idiomatic
#[test]
#[should_panic(expected = "less than or equal to 100")]
fn greater_than_100() { Guess::new(200); }

// Avoid
#[test]
#[should_panic] // passes even if Guess::new panics for the wrong reason
fn greater_than_100() { Guess::new(200); }
```

Tests may return `Result<(), E>`, letting you use `?` to propagate errors instead of unwrapping. Note `#[should_panic]` cannot be combined with a `Result`-returning test — assert `value.is_err()` instead.

```rust
#[test]
fn it_works() -> Result<(), String> {
    if 2 + 2 == 4 { Ok(()) } else { Err(String::from("two plus two does not equal four")) }
}
```

## What only tests can catch

The compiler eliminates whole classes of bugs (use-after-free, data races in safe code, null derefs), but **no compiler catches logic errors** — wrong branch conditions, off-by-one math, a missing authorization check. In Rust these become your dominant bug class precisely because the memory bugs are gone, so spend test effort on business-rule correctness.

```rust
#[test]
fn withdraw_cannot_go_negative() {
    assert!(withdraw(balance, amount_exceeding_balance).is_err());
}
```

Write tests from the **external specification**, not from your own implementation. Deriving expected values by running your code and pasting the output back only re-encodes whatever bug it already has. For a binary format read the magic bytes from the file-format spec; for a protocol read the RFC.

```rust
// Idiomatic — bytes come from the .DS_Store format spec, not from the parser
let valid = [0x00,0x00,0x00,0x01,0x42,0x75,0x64,0x31,0x00,0x00,0x30,0x00];
assert!(module.is_ds_store_file(&valid));
assert!(!module.is_ds_store_file(b"testtesttest"));
```

## Async tests

Use `#[tokio::test]` to `await` directly inside a test function. It spins up a runtime for the test, so you avoid hand-rolling `Runtime::new().block_on(...)` in every case.

```rust
// Idiomatic
#[tokio::test]
async fn lists_directory() {
    let m = DirectoryListingDisclosure::new();
    assert!(m.is_directory_listing("<title>Index of foo</title>".into()).await.unwrap());
}

// Avoid
#[test]
fn lists_directory() {
    let rt = tokio::runtime::Runtime::new().unwrap();
    rt.block_on(async { /* boilerplate in every test */ });
}
```

## Concurrency testing

Drive **stress tests** that throw many threads at the same shared state for several seconds. Random scheduling explores interleavings that deterministic sequential tests never reach, shaking out races that only surface under contention.

```rust
// Idiomatic — contend on a tiny key set so threads actually collide
for _ in 0..N_WRITERS { thread::spawn(|| map.insert(key(), val())); }
for _ in 0..M_READERS { thread::spawn(|| { let _ = map.get(&key()); }); }

// Avoid
map.insert(1, "a");
assert_eq!(map.get(&1), Some(&"a")); // never exercises concurrent access
```

Stress tests and model checkers can only catch bugs that *panic or assert*, so sprinkle `debug_assert!` through low-level concurrent code. A silently corrupted index produces no signal unless an assertion fires on the interleaving that triggered it.

```rust
fn push(&self, val: T) {
    let idx = self.head.fetch_add(1, Ordering::Relaxed);
    debug_assert!(idx < self.capacity, "ring buffer overflow");
    // ...
}
```

For small concurrent units, use **`loom`** to exhaustively model-check every interleaving — far more reliable than "it passed a few times". For full suites where Loom's combinatorial blowup is too costly, run **ThreadSanitizer** (`RUSTFLAGS="-Zsanitizer=thread" cargo +nightly test`), whose ~5–15× overhead is constant rather than exponential.

```rust
#[test]
fn loom_counter() {
    loom::model(|| {
        let n = loom::sync::Arc::new(loom::sync::atomic::AtomicUsize::new(0));
        // ... spawn loom threads, assert invariants ...
    });
}
```

Run unsafe code under **Miri** (`cargo miri test`). UB like reading uninitialized memory or aliasing two `&mut` to one value may pass normal tests silently; Miri interprets MIR and reports the violation the instant it happens.

```rust
// Miri flags this immediately; a normal `cargo test` may pass
let p: *mut i32 = &mut x;
let (a, b) = unsafe { (&mut *p, &mut *p) }; // two &mut to the same value — UB
```

## Integration tests

Files directly under `tests/` are each compiled as a separate crate exercising only the **public API**. Shared helpers must live in a subdirectory module (`tests/common/mod.rs`), not `tests/common.rs` — the latter is treated as its own test target and produces an empty test section in the output.

```rust
// tests/common/mod.rs
pub fn setup() { /* ... */ }

// tests/integration_test.rs
mod common;

#[test]
fn it_adds_two() {
    common::setup();
    assert_eq!(4, adder::add_two(2));
}
```

## Running tests well

`cargo test` runs tests **in parallel** by default. Tests that share files, environment variables, or global state will race and fail non-deterministically. Make each test self-contained — e.g. give every temp file a unique name.

```rust
// Idiomatic
let path = format!("/tmp/test-{}", std::process::id());

// Avoid
let path = "test-output.txt"; // every test writes here — they race
```

Mark slow tests `#[ignore]` so the default run stays fast enough to invoke often; opt into them with `cargo test -- --ignored`.

```rust
#[test]
#[ignore]
fn expensive_test() { /* takes minutes */ }
```

## Doc tests

Put runnable examples in `///` doc comments. `cargo test` compiles and runs them, so documentation cannot silently drift out of sync with the implementation. Prose-only examples are never checked.

```rust
/// Adds one to the number given.
///
/// ```
/// let answer = my_crate::add_one(5);
/// assert_eq!(6, answer);
/// ```
pub fn add_one(x: i32) -> i32 { x + 1 }
```

Use a `compile_fail` doctest to assert that a misuse is *rejected by the compiler*. Runtime tests cannot check type-system guarantees like `!Send`/`!Sync`; a `compile_fail` example documents the invariant in the public docs and fails CI if a future change accidentally makes the forbidden code compile.

```rust
/// ```compile_fail
/// fn is_send<T: Send>() {}
/// is_send::<MyNonSendType>(); // must NOT compile
/// ```
```

## Test layers

Use the layers as complementary — each catches a different class of regression:

- **Unit tests** (`src/` `#[cfg(test)] mod tests`) — internal logic, including private items.
- **Integration tests** (`tests/`) — the public API boundary.
- **Doc tests** (`///` examples) — keep documented samples accurate.
- **Examples** (`examples/`, run via `cargo test --examples`) — real-world usage.

In `examples/`, return `Result` from `main` and use `?` rather than `unwrap`. Users copy-paste examples, so they should model idiomatic error handling.

```rust
// Idiomatic
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let data = read_file("input.txt")?;
    process(data)?;
    Ok(())
}

// Avoid
fn main() {
    let data = read_file("input.txt").unwrap(); // teaches panicking-by-default
    process(data).unwrap();
}
```

## TDD and lints

Write the failing test **before** the implementation (red-green-refactor). Defining the expected API and behavior up front yields high coverage by construction and surfaces design problems early.

Run Clippy in CI and keep it warning-free (`cargo clippy -- -D warnings`). It catches correctness bugs (failed swaps, a forgotten `&`, iterating only the first element) the compiler ignores. Silence individual opinionated lints with a targeted `#[allow(clippy::name)]` rather than disabling Clippy wholesale, which throws away all the high-value correctness signal.

```rust
// Idiomatic — suppress one noisy lint, keep the rest
#[allow(clippy::type_complexity)]
fn handlers() -> Rc<Vec<Box<(u32, u32, u32, u32)>>> { /* ... */ }

// Avoid: disabling Clippy in CI to silence one warning
```

Turn on `missing_docs` and `missing_debug_implementations` at **project inception**, not later. They are opt-in lints; enforcing them from line one makes each doc comment and `Debug` impl a cheap incremental habit, whereas retrofitting them across a large crate is a slog.

```rust
#![warn(missing_docs, missing_debug_implementations, rust_2018_idioms)]
```

## Fuzzing and property testing

When code processes untrusted, attacker-controlled input, add coverage-guided fuzzing (`cargo-fuzz` / libFuzzer) — even safe Rust can panic on unexpected input, enabling denial-of-service.

```rust
// fuzz/fuzz_targets/target1.rs
#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let _ = somecrate::parse(data);
});
```

For functions whose input is *structured*, derive `Arbitrary` so the fuzzer builds semantically valid instances (`Vec`s, `HashMap`s, multi-field structs) instead of feeding raw bytes that get rejected immediately. This reaches deep, type-specific code paths a `&[u8]` never would.

```rust
// Idiomatic
#[derive(Clone, Debug, arbitrary::Arbitrary)]
struct MyInput { data: Vec<u8>, n: usize }

fuzz_target!(|input: MyInput| { my_function(&input.data, input.n); });

// Avoid
fuzz_target!(|data: &[u8]| { my_function(data, data.len()); }); // misses field interactions
```

Fuzzing only catches panics. **Property testing** (`proptest`) lets you assert *correctness* by cross-checking against a simple, obviously-correct reference implementation: feed both the optimized and the naive version the same generated input and assert they agree. A non-crash check is too weak — a function that always returns `[]` passes it.

```rust
// Idiomatic — every disagreement is an actionable bug
proptest!(|(v: Vec<i32>)| {
    prop_assert_eq!(optimized_sort(v.clone()), naive_sort(v));
});

// Avoid: only asserting the function "doesn't panic"
```

## Benchmarking

Wrap reads and writes with `std::hint::black_box` so the optimizer cannot delete the code under test as dead. Use the **pointer form** `black_box(v.as_ptr())`, not `black_box(&v)`: an immutable reference still lets the compiler reason the value is unchanged and elide e.g. a `Vec::push` loop, whereas an observed raw pointer forces it to treat the buffer as live.

```rust
// Idiomatic
black_box(vs.as_ptr());
vs.push(i);
black_box(vs.as_ptr());

// Avoid
b.iter(|| factorial(15));      // result folded to a constant
black_box(&vs);                // immutable borrow — loop may still be optimized away
```

Keep the measured loop body to the operation under test only: no I/O, no RNG, no timing calls. A single `println!` inside a million-iteration loop dominates the measurement (it locks stdout, formats, syscalls) and the real function vanishes into the noise. Move all setup outside the region.

```rust
// Idiomatic
let input = rand::random::<u64>(); // generated once, outside the hot loop
for _ in 0..1_000_000 { black_box(my_function(input)); }

// Avoid
for i in 0..1_000_000 { println!("iter {i}"); my_function(); } // measuring println!
```
