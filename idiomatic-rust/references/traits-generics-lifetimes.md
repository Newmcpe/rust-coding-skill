# Traits, Generics & Lifetimes

How to express abstraction, dispatch, and borrow relationships idiomatically in Rust.

## Generics & Trait Bounds

Unify functions that differ only in concrete type into one generic. The body dictates the bounds: declare a bound only when the body uses that behavior, but declare it as soon as it does — unbounded generics compile yet fail at the call site with cryptic errors. Stating `T: PartialOrd` in the signature makes the requirement part of the contract and produces precise diagnostics.

```rust
// Idiomatic
fn largest<T: PartialOrd>(list: &[T]) -> &T { /* ... */ }

// Avoid
fn largest_i32(list: &[i32]) -> &i32 { /* ... */ }   // duplicated per type
fn largest<T>(list: &[T]) -> &T { /* uses `>` */ }   // compiles, breaks at use
```

Constrain generics by capability, not by concrete type. `fn add<T: Add<Output = T>>(x: T, y: T) -> T` works for every numeric type, including user-defined ones; writing separate `add_i64`/`add_f64` duplicates logic that must then be bug-fixed in each copy.

Keep the parameter count small. More than two or three generic parameters signals the type is doing too much; split it instead. Use a `where` clause once bounds get dense so each constraint sits on its own line rather than crowding the signature.

```rust
fn some_function<T, U>(t: &T, u: &U) -> i32
where
    T: Display + Clone,
    U: Clone + Debug,
{ /* ... */ }
```

Don't reach for generics gratuitously. Every distinct instantiation is monomorphized into a separate copy, and excess generics are the single largest driver of long Rust compile times and binary bloat. When the runtime cost is acceptable and the type is fixed at the call site, take a concrete type or `dyn Trait` instead of inventing a type parameter (`fn send(client: &reqwest::Client, url: &str)` over `fn send<C: HttpClient, U: AsRef<str>>(...)`).

Compose capability requirements with `+` (`T: Module + SubdomainModule`) rather than inventing a fat trait that just re-declares the members of two existing ones. Composition lets each trait be implemented and reused independently.

Gate methods behind conditional `impl` blocks so a capability is advertised in the `impl` signature and only exists on instantiations that satisfy it — clearer than burying a `where` clause on each method.

```rust
impl<T: Display + PartialOrd> Pair<T> {
    fn cmp_display(&self) { /* ... */ }
}
```

When the compiler lacks context to infer a generic return type, supply it inline with turbofish rather than a separate annotated `let`:

```rust
fields[1].parse::<f32>()   // not: let x: f32 = fields[1].parse()?;
```

## Defining Traits

Bring a trait into scope with `use` before calling its methods; this also documents which capability is in play and avoids ambiguity between same-named methods.

Keep the required surface small and build defaults on top of it. Implementors override only the required methods and inherit the rest (mirroring `Iterator`'s one required method and dozens of defaults). New defaults can be added later without breaking existing impls. This cuts both ways for *implementing* too: when a trait supplies defaults (e.g. `fmt::Write` requires only `write_str`, deriving `write_fmt` and `write!`), implement just the required method and let the rest be generated — hand-writing the derived ones duplicates logic and risks drift.

```rust
pub trait Summary {
    fn summarize_author(&self) -> String;
    fn summarize(&self) -> String {
        format!("(Read more from {}...)", self.summarize_author())
    }
}
```

Respect the orphan rule: implement a trait only when the trait or the type is local to your crate. Use a **supertrait** (`trait OutlinePrint: Display`) to require another trait once at the definition instead of repeating `where Self: Display` on every method. Use **fully qualified syntax** to disambiguate same-named associated functions, which (unlike methods) have no `self` for inference:

```rust
println!("{}", <Dog as Animal>::baby_name());
```

Prefer encoding behavior as a trait over runtime reflection or `type_name`/`Any` string checks — traits are statically verified, zero-overhead, and composable. Reach for derive macros for compile-time codegen rather than downcasting `dyn Any` at runtime. Mark a trait `unsafe` only when the invariant can't be defended at runtime (e.g. `Send`/`Sync` thread-safety); for tolerable bugs (a wrong `Ord`) keep it safe.

### Sealing & API evolution

Seal a trait you want downstream crates to *use but not implement*: give it a private supertrait from a private module. Sealing keeps the freedom to add methods, add blanket impls, and implement the trait for new foreign types without those changes counting as breaking — no external impl can ever conflict.

```rust
pub trait CanUse: sealed::Sealed { /* ... */ }
mod sealed {
    pub trait Sealed {}
    impl<T: Bounds> Sealed for T {}
}
```

### Async methods in traits

Prefer native `async fn` in traits (stable since Rust 1.75) — it returns an unboxed future and needs no dependency. Reach for the `async-trait` crate **only** when you need one of the things native AFIT still lacks: a `dyn Trait` object (native AFIT is not `dyn`-compatible) or a `Send` bound on the returned future across a generic boundary. Defaulting to `async-trait` everywhere boxes every future needlessly. The example below needs `async-trait` precisely because it is used as `Arc<dyn Spider>` across `tokio::spawn`.

```rust
#[async_trait]
pub trait Spider: Send + Sync {        // Send + Sync so Arc<dyn Spider> crosses tokio::spawn
    type Item;
    async fn scrape(&self, url: String) -> Result<(Vec<Self::Item>, Vec<String>), Error>;
}
```

Add `Send + Sync` to a trait whose objects are shared across threads in async code: `tokio::spawn` requires `Future: Send`, and `Arc<dyn Trait>` is only `Send + Sync` if the trait itself requires it. Without the bound, spawn rejects the object.

## Const generics

Make a type or function generic over a constant value (usually an array length) with `const N: usize`, instead of hardcoding sizes or falling back to heap `Vec` when the size is known at compile time.

```rust
// Idiomatic: one impl covers every length, checked at compile time, no allocation
struct Matrix<const R: usize, const C: usize> { data: [[f64; C]; R] }
fn sum<const N: usize>(xs: [i32; N]) -> i32 { xs.iter().sum() }

// Avoid: a separate type per size, or heap indirection for a compile-time-known length
struct Matrix3x3 { data: Vec<Vec<f64>> }
```

Const generics let `[T; N]` implement traits uniformly (the standard library uses them so arrays of any length are `IntoIterator`, `Default`-able, etc.). Reach for them for fixed-size buffers, dimensions, and lookup tables; the dimensions become part of the type, so mismatches are compile errors. (For returning different concrete types per impl, see GATs / `impl Trait` in associated types when an associated type must itself be generic over a lifetime or type.)

## Associated Types vs Generic Trait Parameters

Use an associated type when there is exactly one logical implementation per type. A generic trait parameter permits `impl Iterator<u32>` *and* `impl Iterator<String>` for the same type, forcing callers to annotate which they mean; `type Item` allows only one impl and keeps call sites unambiguous. The win compounds at call sites: `fn use_spider<S: Spider>` versus dragging an extra variable through every signature (`fn use_spider<I, S: Spider<I>>`). Reserve generic trait parameters for the genuine multi-impl case like `PartialEq<Rhs>`.

```rust
// Idiomatic
pub trait Iterator {
    type Item;
    fn next(&mut self) -> Option<Self::Item>;
}

// Avoid
pub trait Iterator<T> { fn next(&mut self) -> Option<T>; }
```

## Static Dispatch vs Trait Objects

Default to generics with trait bounds: monomorphization gives static dispatch, inlining, and zero overhead, and lets you combine multiple bounds (`T: Debug + Draw`) to gate methods at compile time. Methods are statically dispatched *unless* you explicitly write `dyn`, so static is the path of least resistance. Reach for `Box<dyn Trait>` / `&dyn Trait` only when the concrete type must vary at runtime — heterogeneous collections, or storing differently-typed values together — accepting a vtable indirection, lost inlining, but smaller code than mass monomorphization.

```rust
// Homogeneous, static dispatch — preferred
pub struct Screen<T: Draw> { pub components: Vec<T> }

// Heterogeneous, runtime dispatch — only when types must mix
let party: Vec<Box<dyn Draw>> = vec![Box::new(a), Box::new(b)];
```

**Library vs binary.** In a *library*, prefer static dispatch (`impl Trait` / generics) so callers keep the freedom to choose; accepting `&dyn Trait` in a public API forces dynamic dispatch on everyone forever. In a *binary*, dynamic dispatch is often the better default — you pay only a vtable lookup and gain cleaner, faster-compiling code.

A supertrait bound (`Shape: Draw`) means "also implements," not "is-a": `&dyn Shape` cannot be upcast to `&dyn Draw`. To keep a trait object-safe, bound `Self`-returning or `Self`-sized methods with `where Self: Sized` so they are excluded from the vtable. Use a `self: Box<Self>` receiver to consume a boxed trait object and return a new state — a bare `self` receiver isn't usable on an unsized trait object.

```rust
trait State {
    fn request_review(self: Box<Self>) -> Box<dyn State>;
}
```

Condense verbose boxed types with a type alias (no runtime cost):

```rust
type Job = Box<dyn FnOnce() + Send + 'static>;
```

## impl Trait

In **parameter** position, `impl Trait` is concise when parameters are independent; switch to explicit `<T: Trait>` when two parameters must share one concrete type. In **return** position, `impl Trait` resolves to a single concrete type — returning different types from different branches is an error, so use `Box<dyn Trait>` for that case.

```rust
fn notify<T: Summary>(a: &T, b: &T) {}      // same type required
fn notify(a: &impl Summary, b: &impl Summary) {} // independent types

fn make() -> impl Summary { Tweet { /* ... */ } } // one concrete type
```

Prefer accepting `impl Iterator<Item = T>` over `&[T]` when you only iterate — callers can pass any iterator with no forced intermediate `Vec`. The same instinct applies to I/O: bound a helper by `R: Read` / `T: BufRead` so one code path serves `File`, `stdin`, sockets, and `Cursor<Vec<u8>>` — and becomes trivially testable with `&[u8]` — instead of duplicating the logic per concrete reader.

```rust
fn process_record<R: Read>(f: &mut R) -> io::Result<KeyValuePair> { /* ... */ }
// not fn process_record(f: &mut BufReader<File>) — locks out test buffers
```

## Closures & Fn Traits

Accept the most permissive `Fn*` bound the body needs (`FnOnce` ⊃ `FnMut` ⊃ `Fn`). Prefer a generic `F: Fn(...)` / `impl Fn(...)` over a bare `fn` pointer so callers can pass capturing closures, not just named functions; reserve `fn` for FFI. Return `impl Fn(...)` for one concrete closure, `Box<dyn Fn(...)>` when it varies across branches.

```rust
// Idiomatic
fn modify_all<F: FnMut(u32) -> u32>(data: &mut [u32], mut f: F) { /* ... */ }

// Avoid
fn modify_all(data: &mut [u32], f: fn(u32) -> u32) { /* rejects closures */ }
```

Use a zero-method **marker trait** to encode invariants with no place in a signature (e.g. `StableSort`), shifting the obligation to the implementer via a trait bound rather than a `bool` flag or doc comment.

## Conversions: From / Into / TryFrom

Implement `From<T>`; the blanket `impl<T, U: From<T>> Into<U> for T` gives you `Into` for free. **Never implement `Into` directly** — it's redundant and blocks the blanket impl. Use `Into` as the *bound* in generic functions so callers can pass anything convertible without wrapping manually. Use `TryFrom`/`TryInto` when conversion can fail; `From` carries an implicit contract that the conversion is lossless and infallible, so a clamping or truncating `From` is a lie — make fallibility visible in the type.

```rust
impl From<u64> for IanaAllocated { fn from(v: u64) -> Self { Self(v) } }

pub fn is_reserved<T: Into<IanaAllocated>>(s: T) -> bool {
    let s = s.into();
    s.0 == 0 || s.0 == 65535
}
```

Chain `From` impls to reuse conversion logic rather than copy-pasting it: if `From<f64>` exists and `f32` widens losslessly to `f64`, define `From<f32>` as a one-line delegation `Q7::from(n as f64)`.

Prefer `TryInto`/`TryFrom` over an `as` cast whenever a numeric conversion can lose data: `300_i32 as i8` silently yields `44`, while `300_i32.try_into()` returns an `Err` the caller must handle. When you *do* use `as`, cast toward the **wider** type (promotion is lossless); demoting to a narrower type silently truncates.

```rust
let widened: i64 = n.try_into()?;   // explicit failure path, not `n as i64`
```

For read-only string arguments, bound by `AsRef<str>` so callers pass either `&str` or `String` with no forced allocation; reach for `Into<String>` only when the body genuinely needs to own/mutate the value (one allocation at the boundary).

```rust
fn is_strong<T: AsRef<str>>(password: T) -> bool { password.as_ref().len() > 5 }
```

Many byte-oriented APIs (AEAD nonces/keys) accept `Into<GenericArray<..>>`; call `.into()` on a `[u8; N]` at the boundary instead of manual `clone_from_slice` plumbing.

## Error Types at Boundaries

At a program boundary (`main`, top-level handlers) that funnels many library error types, return `Result<(), Box<dyn std::error::Error>>` instead of `.unwrap()` or a hand-written wrapper enum — `?` coerces every error into the box and performance is irrelevant there. Define a custom error enum only where callers must match on variants.

```rust
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let body = reqwest::get(url)?.text()?;
    Ok(())
}
```

## Standard Derives

Derive `Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash` at definition time whenever valid — adding them later is a semver-visible change, and the ecosystem expects them. Consistency rules: keep `Eq` with a matching `Hash` (equal values must hash equal, or hash maps corrupt); don't `.clone()` a `Copy` type (redundant); don't derive `Copy` on large types (hides O(N) copies — force an explicit `.clone()`). Implement `Display` for user-facing text; never parse or persist `Debug` output, whose format is unstable — `{:?}` is for developers, `{}` for end users.

`#[derive(Foo)]` emits a `where T: Foo` bound for *every* generic parameter, which is sometimes wrong. For a wrapper over `Arc<T>`, the derive demands `T: Clone` even though `Arc<T>: Clone` regardless of `T` — write the impl by hand so `Shared<NotClone>` stays cloneable. More generally, only offer a derive (or accept one) when the generated impl does the obvious, intuition-matching thing; a derive that silently encrypts, deep-copies through an `Arc`, or otherwise surprises is worse than none. When deriving for a generic struct, also remember to state the bounds the derive actually needs (e.g. `T: for<'de> Deserialize<'de>`) so concrete uses compile.

```rust
impl<T> Clone for Shared<T> {            // not #[derive(Clone)] — that demands T: Clone
    fn clone(&self) -> Self { Shared { inner: Arc::clone(&self.inner) } }
}
```

## Lifetimes

Lifetime annotations live in the **signature**, not the body — they describe relationships between inputs and outputs, not durations. Annotate only the references that are actually related to the output; tying an unrelated parameter to the return lifetime is misleading.

```rust
// Idiomatic — only x is tied to the return
fn longest<'a>(x: &'a str, y: &str) -> &'a str { x }

// Avoid — needlessly constrains y
fn longest<'a>(x: &'a str, y: &'a str) -> &'a str { x }
```

Lean on the three **elision rules** and add explicit names only when the compiler can't map the output: (1) each elided input gets its own lifetime; (2) one input lifetime propagates to all outputs; (3) `&self`/`&mut self` lifetime propagates to all outputs. A function returning a reference with no input to derive it from is an error.

```rust
fn first(data: &[Item]) -> Option<&Item> {}            // elided, fine
fn find<'a>(hay: &'a [u8], needle: &[u8]) -> Option<&'a [u8]> {} // explicit: which input
```

Annotate every reference field in a struct so the struct can't outlive its borrowed data. Don't reach for `'static` to silence a lifetime error — it usually masks a real scope mismatch that should be fixed structurally.

```rust
struct ImportantExcerpt<'a> { part: &'a str }
```

**Keep lifetimes out of public APIs.** Annotations are viral — every caller and every wrapping struct must propagate them — and they compose badly with async. Prefer owning the data (move a `String` in) or sharing with `Arc`/`Rc` over threading `&'a` references through your public surface; reserve lifetime-heavy designs for genuinely performance-critical, internal hot paths.

```rust
// Idiomatic — composes with async, no viral annotations
struct MyService { db: Arc<DB>, mailer: Arc<dyn Mailer> }

// Avoid in public APIs
struct MyService<'a> { db: &'a DB, mailer: &'a dyn Mailer }
```

## Advanced: DSTs, Variance, HRTBs

Dynamically sized types (`str`, `dyn Trait`) have no compile-time size and must live behind a fat pointer (`&str`, `Box<dyn Trait>`, `Rc<str>`). To accept unsized types in a generic, opt out of the implicit `Sized` bound with `?Sized` and take the value by reference:

```rust
fn generic<T: ?Sized>(t: &T) { /* works with str, dyn Trait, ... */ }
```

A longer lifetime is a subtype of a shorter one (`'static: 'a`), so a `&'static T` works wherever a `&'a T` is expected. Keep your types **covariant** in their lifetime parameters where you can — covariance lets a longer-lived reference stand in for a shorter one. `&mut T` and `Cell<T>` force **invariance** (covariance would let you overwrite a `Cat` with a `Dog` through `&mut Animal`), so don't wrap a field in `&'a mut &'a T` when a plain `&'a T` would do — the extra `&mut` needlessly locks out subtyping.

Use `for<'a>` **higher-rank trait bounds** when a closure or generic must work for *any* lifetime, not one fixed at the call site. The compiler inserts `for<'a>` automatically for simple `Fn` bounds over references, but projections and `Deserialize<'de>`-style bounds need it written out — `for<'de> T: Deserialize<'de>` says "deserializable from any lifetime," which a single `'de` parameter cannot express when the buffer's lifetime is internal.

```rust
where F: for<'a> Fn(&'a (u8, u16)) -> &'a u8
where for<'de> T: Deserialize<'de>
```

Rust does not apply coercions when matching trait bounds (only for method receivers): if `&mut i32` coerces to `&i32`, that still doesn't satisfy `X: Trait` when the impl is for `&i32` — implement the trait for the actual type.
