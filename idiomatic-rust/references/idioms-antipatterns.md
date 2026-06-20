# Rust Idioms & Anti-Patterns

Catch-all do-this-not-that rules for clean, idiomatic Rust that the compiler and other readers will thank you for.

## Bindings & mutability

Default to immutable bindings. `mut` is a signal that other code deliberately changes the value; sprinkling it everywhere hides which values are actually constant and invites bugs where one path mutates what another assumed was fixed.

```rust
// Idiomatic
let x = 5;
// Avoid
let mut x = 5; // never mutated
```

Use shadowing to re-bind a name across a type change instead of inventing `_str`/`_num` twins. `mut` cannot change a variable's type, so shadowing is the only idiomatic option for a transform-then-reuse.

```rust
// Idiomatic
let spaces = "   ";
let spaces = spaces.len(); // re-bound as usize, same concept
// Avoid
let spaces_str = "   ";
let spaces_len = spaces_str.len();
```

Prefix intentionally unused bindings with `_` (e.g. `_i`, or bare `_`) to silence the unused-variable lint while keeping it on for genuine mistakes.

Avoid `static mut` for shared mutable state — every read and write requires `unsafe`, and the need for it is a design smell. Reach for an `AtomicBool`/`AtomicUsize` (or a `Mutex`-protected static) instead; even a signal handler can flip an `AtomicBool` with no `unsafe`.

```rust
// Idiomatic
static SHUT_DOWN: AtomicBool = AtomicBool::new(false);
fn handle_sigterm(_: i32) { SHUT_DOWN.store(true, Ordering::Relaxed); }
// Avoid
static mut SHUT_DOWN: bool = false; // every access needs unsafe {}
```

## Expressions over statements

Functions return their final *expression* — no trailing semicolon, and no redundant `return` on the last line. A semicolon turns the expression into a statement that yields `()`, producing a type mismatch. Reserve `return` for early exits.

```rust
// Idiomatic
fn plus_one(x: i32) -> i32 { x + 1 }
// Avoid
fn plus_one(x: i32) -> i32 { return x + 1; } // redundant return
fn plus_one(x: i32) -> i32 { x + 1; }        // returns (), won't compile
```

`if` is an expression: bind its result directly instead of declaring a `mut` and assigning inside each branch. All arms must yield the same type, or the binding has no single type (E0308).

```rust
// Idiomatic
let number = if condition { 5 } else { 6 };
// Avoid
let mut number;
if condition { number = 5 } else { number = 6 }
```

`loop` is also an expression: return a retry result with `break <value>` rather than threading a `mut` accumulator and a flag through the loop.

```rust
let result = loop {
    counter += 1;
    if counter == 10 { break counter * 2; }
};
```

`if` conditions must be `bool`. Rust never coerces integers or other types to truthiness like C or JS — write the explicit comparison (`if number != 0`).

Use `loop` for an unconditional infinite loop, not `while true`. `loop` states intent and the compiler treats it specially for control-flow and reachability analysis.

Give a function the never type `-> !` when it is guaranteed to diverge (always panics, loops forever, or calls `process::exit`). A diverging call type-checks in *any* position, so `panic!()` / `unimplemented!()` can sit in a `match` arm or `if`/`else` branch that must yield a concrete type without inventing a placeholder value.

```rust
fn dead_end() -> ! { panic!("unreachable") }
let port = parse(s).unwrap_or_else(|| dead_end()); // diverging arm satisfies u16
```

## Control flow: match, if let, while let

Prefer `match` over long `else if` chains (more than two branches) and over `if let` whenever exhaustiveness matters. `match` forces you to handle every variant; `if let` silently drops the unhandled case, hiding logic bugs.

```rust
// Idiomatic — compiler enforces the None case
match opt {
    Some(v) => use_value(v),
    None => handle_none(),
}
// Avoid — None silently ignored
if let Some(v) = opt { use_value(v); }
```

Use `if let` only for *refutable* patterns and plain `let` only for *irrefutable* ones. `let Some(x) = opt;` fails to compile (None uncovered); `if let x = 5` warns about a pointless branch.

Use `while let` to drain `Option`-yielding sources instead of a `loop`/`match`/`break`:

```rust
while let Some(top) = stack.pop() {
    println!("{top}");
}
```

In tuple/slice patterns, `..` may appear at most once — `(.., x, ..)` is ambiguous and rejected. One `..` at front, middle, or end is fine: `(first, .., last)`.

Use a labelled `break 'outer` to escape nested loops instead of threading a `mut done` flag (or splitting into a function just to `return`). The flag adds mutable state and obscures the exit condition.

```rust
'outer: for x in 0.. {
    for y in 0.. {
        if x + y > 1000 { break 'outer; }
    }
}
```

## Less duplication, less mutable state

Prefer iterator chains over manual `for` loops that push into a `mut` vector. Minimizing mutable state is easier to reason about and unlocks future parallelism.

```rust
// Idiomatic
contents.lines().filter(|l| l.contains(query)).collect()
// Avoid
let mut results = Vec::new();
for line in contents.lines() {
    if line.contains(query) { results.push(line); }
}
results
```

Pass an enum tuple-variant constructor directly to `map` — each is already a function pointer, so the wrapping closure is redundant: `(0..20).map(Status::Value)` not `.map(|i| Status::Value(i))`.

Extract the *varying* values from near-identical branches into bindings and write the shared logic once. This narrows the diff between cases and gives a single update point.

```rust
let (status_line, filename) = if request_line == "GET / HTTP/1.1" {
    ("HTTP/1.1 200 OK", "hello.html")
} else {
    ("HTTP/1.1 404 NOT FOUND", "404.html")
};
let contents = fs::read_to_string(filename).unwrap();
```

Give shared behavior a *default trait method* rather than copying the same body into each implementor; overriding stays available where a type differs.

## Closures & the Fn traits

Don't move a value out of a closure body when the caller needs `FnMut`. Moving makes it `FnOnce` (callable once); APIs like `sort_by_key` call repeatedly. Mutate a captured `mut` binding instead.

```rust
// Idiomatic
let mut count = 0;
list.sort_by_key(|r| { count += 1; r.width });
// Avoid — E0507: cannot move out of captured var in FnMut
list.sort_by_key(|r| { ops.push(owned_string); r.width });
```

Accept callbacks by the `Fn`/`FnMut`/`FnOnce` traits (`fn apply<F: Fn(u8) -> T>(f: F)`), not by a bare `fn` pointer. A `fn` parameter rejects every closure that captures state; a generic trait bound takes both closures and plain functions.

## Imports

Avoid glob imports (`use path::*`) in production code — they hide where each name came from and invite silent collisions as dependencies evolve. They're fine in test modules (`use super::*`) and for intentional crate preludes.

Bring the *parent module* into scope rather than the function when it would otherwise read like a local definition. `env::args()` is unambiguous; a bare `args()` from `use std::env::args` looks locally defined.

```rust
use std::env;
let args: Vec<String> = env::args().collect();
```

## Conversions & types

Annotate `collect()` — it can build many collection types, so the compiler needs the target (`let v: Vec<String> = it.collect();`).

Prefer `From`/`Into` (and `TryFrom`/`TryInto`) over `as` casts for numbers. `as` silently truncates (`u32 as u16` wraps); `From` is rejected by the compiler for lossy conversions, and `TryFrom` surfaces the failure explicitly.

```rust
// Idiomatic
let y: u64 = x.into();
// Avoid
let y = x as u16; // silently lossy when x > u16::MAX
```

When CLI args may contain non-UTF-8 bytes, use `env::args_os` (yields `OsString`) — `env::args` panics on invalid Unicode.

Manipulate filesystem paths with `Path`/`PathBuf`, never raw `String` splitting on `'/'`. String surgery is off-by-one-prone and breaks on Windows separators — `"/tmp/hi".split('/').next()` is `Some("")`, not `Some("/tmp")`. `PathBuf::pop()` / `join()` do the right thing on every platform.

Use byte-string literals (`b"..."`) when building raw protocol or binary bytes rather than `"...".as_bytes()`. It makes the byte nature explicit and avoids any implicit UTF-8/Unicode assumption creeping into a wire format.

Prioritize clarity over premature zero-copy heroics. Rust makes allocations visible (`clone()`, `to_vec()`, `Box::new()`), which tempts over-optimization. A visible `.to_vec()` that keeps signatures clean beats threading `&'a [u8]` and lifetime parameters through every struct to dodge one allocation — optimize only after benchmarks prove it matters.

Don't over-engineer with lifetime-saturated generics when a plain function, `Arc`, or smart pointer does the job. Inscrutable `where for<'a> ...` bounds produce error messages no one can read; if you are fighting the type system this hard, the design is wrong, not the compiler.

## Numerics & floating point

Integer overflow panics in debug builds but **silently wraps** in `--release`. Never rely on the debug panic to catch overflow in production. When overflow is possible and meaningful, opt in explicitly: `checked_add` (returns `Option`), `saturating_add`, `wrapping_add`, or `overflowing_add` (returns `(value, did_overflow)`).

```rust
// Idiomatic
let n = a.checked_add(b).ok_or("overflow")?;
let (val, carry) = x.overflowing_add(y); // handle carry explicitly
// Avoid
let n = x + 1; // panics in debug, wraps to 0 in release for u8::MAX
```

Never test floats for exact equality; compare within a tolerance. Decimal values like `0.1` have no exact binary representation, and `f32` vs `f64` widths give bit-different results. Pick the tolerance for your domain — `f32::EPSILON` is only the gap near `1.0`, so it is far too tight for large magnitudes and needlessly loose for tiny ones. Use a relative (or ULP-based) comparison instead of a blanket absolute epsilon.

```rust
// Idiomatic: relative tolerance scaled to the operands' magnitude
let tol = 1e-6 * desired.abs().max(result.abs()).max(1.0);
assert!((desired - result).abs() <= tol);
// Avoid: f32::EPSILON as a universal tolerance — wrong at most magnitudes
assert!((desired - result).abs() <= f32::EPSILON);
// Avoid: exact equality
assert!(0.1_f64 + 0.2 == 0.3); // false on most platforms
```

Guard against `NaN` with `is_nan()` / `is_finite()` before trusting a float result. `NaN` is never equal to anything including itself, so it propagates silently — even `assert_eq!(x, x)` panics when `x` is `NaN`. An explicit `is_finite()` check fails loudly near the source instead.

Parenthesize the receiver when applying unary minus to a float literal before a method call: method calls bind tighter than unary minus, so `-1.0_f32.powf(p)` is `-(1.0.powf(p))`, not `(-1.0).powf(p)`. Write `(-1.0_f32).powf(p)`.

## Performance & memory layout

Prefer stack-allocated (`Sized`) values; reach for `Box`/`Vec` only when the size is unknown at compile time or you genuinely need indirection/sharing. A heap allocation costs a pointer hop, a page-table lookup, and an unpredictable trip through the allocator — `Box::new(40i32)` buys nothing over a plain `i32`.

Keep hot working sets small and contiguous to stay within CPU cache and the TLB (~100 page entries on x86). Favor `Vec<Particle>` over `Vec<Box<Particle>>`: each `Box` adds an indirection and scatters elements across pages, defeating the prefetcher and cache.

Extract type-independent logic into a non-generic inner function called from a generic wrapper. The compiler monomorphizes the whole generic body once *per concrete type*; code that doesn't depend on the type parameter is duplicated needlessly. An inner `fn` is compiled once and shared.

```rust
fn insert<K: Hash + Eq, V>(map: &mut RawMap, key: K, val: V) {
    let hash = compute_hash(&key);   // type-dependent
    insert_at_hash(map, hash, val);  // non-generic, compiled once
}
```

Use `Instant` (monotonic) for measuring elapsed time, never `SystemTime` wall-clock differences. Wall-clock time can jump *backwards* (NTP, leap seconds), making `t2.duration_since(t1)` panic or yield garbage. Request a monotonic clock whenever ordering events.

```rust
// Idiomatic
let start = Instant::now();
let elapsed = start.elapsed();
```

## Macros (last resort)

Think twice before any macro — first try to cut the complexity structurally with a function, generic, or trait. Escalate function → generic → macro. If behavior varies *by type*, use a generic (it cooperates with inference, trait bounds, and tooling); reach for `macro_rules!` only when the repetition genuinely cannot be expressed with generics. Macros hurt readability, slow compiles, confuse rustfmt/rust-analyzer, and produce cryptic errors.

```rust
// Idiomatic
fn process<T: Trait>(x: T) { /* ... */ }
// Avoid
macro_rules! process_for { ($t:ty) => { fn process(x: $t) { /* ... */ } }; }
```

Keep these rules when a macro is genuinely warranted:

- **Use fully-qualified paths and `$crate`.** A macro expands at the call site, where the caller may have shadowed `Result`, redefined `Option`, or be in a `no_std` crate. Write `::core::option::Option::None` and `$crate::Thing`, never bare names or `::std::...` paths — `::core`/`::alloc` paths and `$crate` are the only universally-correct forms.
- **No hidden non-local control flow.** A macro that secretly `return`s or `?`-propagates is invisible at the call site. Emit a `Result` and let the caller write the visible `?`.
- **Evaluate side-effecting arguments once.** Macro args are substituted textually and may expand multiple times. Bind to a local first (`let x = $e; x * x`) so `square!({ n += 1; n })` doesn't run the increment twice.
- **Build on `format_args!`** for custom formatting macros to inherit compile-time-checked, type-safe format specifiers instead of reinventing string concatenation.
- **Prefer derive macros** over function-like/attribute proc macros for per-field or per-variant codegen — `#[derive(Debug, Clone, PartialEq)]` is idiomatic and recognizable; a proc macro that regenerates a whole type is surprising.

## Derives, attributes & config

Derive `Debug`, `Clone`, `Serialize`, and `Deserialize` together on public DTO / wire types: `Debug` for logging and tests, `Clone` for callback patterns, and the serde pair for encoding. Internal types that never cross an API boundary should derive only what they actually use, so you don't accidentally bake in extra semantics.

Scope `#[allow(dead_code)]` / `#[allow(unused_variables)]` to the specific item while sketching an API, not crate-wide with `#![allow(...)]`. A blanket inner attribute hides real warnings everywhere else; a per-`fn` attribute silences only the stub.

Gate debug-only diagnostics behind `if cfg!(debug_assertions)` and print with `eprintln!`, not stray `println!`. The guarded block compiles out entirely in `--release` (zero overhead), and `eprintln!` keeps stdout clean for real output.

```rust
if cfg!(debug_assertions) { eprintln!("debug: {record:?} -> {fields:?}"); }
```

Prefer environment variables (with the `dotenv` crate) over committed config files for server settings. The same code path reads a local `.env` in development and real environment variables in production, integrating cleanly with containers and CI — no recompile per environment.

## Security & cryptography

Never hand-roll cryptographic primitives. Use audited crates (`ring`, `aes-gcm`, `chacha20poly1305`, `ed25519-dalek`) and prefer the hardest-to-misuse option: `XChaCha20-Poly1305`, whose 192-bit nonce eliminates birthday-bound reuse and needs no special CPU instructions, over AES-GCM. Algorithmic correctness is not enough — DIY code leaks through timing and side channels.

Zeroize key material the moment you finish with it via the `zeroize` crate; do not rely on `Drop`. Symmetric keys and X25519 shared secrets linger in heap/stack memory and are recoverable from swap, core dumps, or cold-boot attacks until explicitly overwritten.

```rust
let mut shared = x25519(private, public);
let mut key = derive_key(&shared);
cipher.encrypt(&nonce.into(), plaintext)?;
shared.zeroize();
key.zeroize();
```

## Ranges

Use inclusive `start..=end` when the upper bound is part of the valid set. `1..=100` includes 100; writing `1..101` to mean the same thing is an off-by-one waiting to happen.
