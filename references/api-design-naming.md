# API Design & Naming

Write Rust public APIs that callers immediately recognize: standard casing, conventional constructors, the most general argument types, and signatures that communicate intent.

## Casing conventions

The compiler warns on violations, and the casing itself carries information: a reader distinguishes a constant from a local, or a type from a function, by case alone. Match the standard library so your code reads like the rest of the ecosystem.

- `snake_case` for functions, methods, variables, and modules.
- `CamelCase` for types, traits, and enum variants.
- `SCREAMING_SNAKE_CASE` for `const` and `static` items.

```rust
// Idiomatic
const MAX_POINTS: u32 = 100_000;
static HELLO_WORLD: &str = "Hello, world!";
fn calculate_area(side_length: f64) -> f64 { side_length * side_length }

// Avoid
const maxPoints: u32 = 100_000;          // looks like a variable
fn calculateArea(sideLength: f64) -> f64 { sideLength * sideLength } // not idiomatic
```

### Mirror standard-library names for familiar operations

API consumers already know `insert`/`get`/`remove`/`with_capacity` from `std`. Inventing synonyms (`store`, `fetch`, `set`) forces callers to learn new vocabulary for no gain. When your type behaves like a `HashMap`, a `Vec`, or an iterator, defer naming to the `std` analog.

```rust
// Idiomatic — a key/value store named like HashMap
pub fn get(&self, key: &ByteStr) -> io::Result<Option<ByteString>>;
pub fn insert(&mut self, key: &ByteStr, value: &ByteStr) -> io::Result<()>;

// Avoid — novel verbs for the same operations
pub fn fetch(&self, ...);
pub fn store(&mut self, ...);
```

## Constructors

Rust has no built-in constructor syntax, so the ecosystem relies on a strong convention: an associated function (no `self`) that returns `Self`, namespaced under the type and called with `::`. Following it makes your type instantly familiar — every reader knows `Foo::new()` produces a `Foo`.

- Use `new` as the primary, default constructor. Provide it on concrete types rather than expecting callers to reach for `Default`; `Default` is for generic contexts, not the main construction entry point.
- Give alternate constructors descriptive names (`Rectangle::square`, `Vec::with_capacity`).
- Prefer associated functions over free functions like `make_square`: they group construction with the type and are discoverable via `Type::`.

```rust
// Idiomatic
impl Rectangle {
    fn new(width: u32, height: u32) -> Self { Self { width, height } }
    fn square(size: u32) -> Self { Self { width: size, height: size } }
}
let sq = Rectangle::square(3);

// Avoid
fn make_square(size: u32) -> Rectangle { Rectangle { width: size, height: size } }
```

### Fallible constructors return `Result`, and aren't named `new`

Callers assume `new` always succeeds. If construction can fail, return `Result` and name it `build` or `try_new` so the call site sees the fallibility. Never let a `new` panic on bad input.

```rust
// Idiomatic
impl Config {
    pub fn build(args: &[String]) -> Result<Config, &'static str> {
        if args.len() < 2 { return Err("not enough arguments"); }
        Ok(Config { /* ... */ })
    }
}

// Avoid
impl Config {
    pub fn new(args: &[String]) -> Config {
        if args.len() < 2 { panic!("not enough arguments"); } // surprises callers
        Config { /* ... */ }
    }
}
```

## Method receivers communicate access

Pick the weakest receiver that does the job. The receiver is part of the contract: `&self` promises read-only, `&mut self` warns of mutation, and `self` (owned) tells callers the instance is consumed and can't be used afterward. Over-asking (e.g. `&mut self` for a getter) needlessly constrains callers.

```rust
fn area(&self) -> u32 { self.width * self.height }   // read-only
fn resize(&mut self, factor: u32) { /* ... */ }      // mutates in place
fn into_string(self) -> String { /* ... */ }         // consumes / transforms
```

Group operations on a type as methods in its `impl` block rather than scattering free functions. Methods are discoverable through `value.`, use ergonomic call syntax, and keep all behavior for a type in one place.

```rust
// Idiomatic
impl Rectangle {
    fn area(&self) -> u32 { self.width * self.height }
    fn can_hold(&self, other: &Rectangle) -> bool {
        self.width > other.width && self.height > other.height
    }
}

// Avoid
fn area(rect: &Rectangle) -> u32 { rect.width * rect.height }
fn can_hold(a: &Rectangle, b: &Rectangle) -> bool { /* ... */ }
```

## Accept the most general argument type

Take borrowed slice types, not borrowed owned types. A `&String` forces every caller to have a `String`; a `&str` accepts string literals, slices, and `&String` (which derefs automatically) with zero allocation. The same reasoning favors `&[T]` over `&Vec<T>`. Borrow for reading; return owned values when you produce new data.

```rust
// Idiomatic — works with literals and Strings alike
fn first_word(s: &str) -> &str { s.split_whitespace().next().unwrap_or("") }

// Avoid — callers must own a String
fn first_word(s: &String) -> &str { /* ... */ }
```

Annotate every parameter type explicitly — Rust requires it in signatures by design, so the compiler gives precise errors and callers read a fully specified contract.

### Generic bounds beat concrete types, with one caveat

Go one step further than `&str`/`&[T]`: take `impl AsRef<str>`, `impl Read`, or `impl IntoIterator` so callers pass whatever they have without manual conversions. The bound states the *minimum* contract you need. Caveat: widening a concrete parameter to a generic one is not always backward-compatible — it can break callers that relied on type inference (e.g. an ambiguous `.collect()` or integer literal), so make the type generic from the start when you can.

```rust
// Idiomatic
fn process(s: impl AsRef<str>) { let s = s.as_ref(); /* ... */ }

// Avoid — caller must hand-deref a String, or is needlessly restricted
fn process(s: &str) { /* ... */ }
fn process(v: &Vec<usize>) { /* ... */ } // &[usize] or impl bound is freer
```

### Require owned data instead of cloning internally

When your function must *store* its input, take it by value (`String`, not `&str`). Cloning inside the body hides the allocation from the caller and steals their control over when it happens; an owned parameter is honest about the cost and lets a caller who already owns the value move it in for free.

```rust
// Idiomatic — caller decides whether to clone at the call site
fn set_name(&mut self, name: String) { self.name = name; }

// Avoid — every call allocates, even when the caller could have moved
fn set_name(&mut self, name: &str) { self.name = name.to_string(); }
```

## Derive the common traits eagerly

Coherence forbids downstream users from implementing foreign traits on your types, so any trait you *don't* provide is one they cannot add — forcing ugly newtype wrappers. Derive `Debug`, `Clone`, `PartialEq`, and `Default` on essentially every public type, and confirm `Send`/`Sync` hold (a raw pointer or `Rc` field silently revokes them, breaking all threaded and most async use). When you genuinely cannot provide one, document why.

```rust
// Idiomatic
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Config { /* ... */ }

// Avoid — no Debug, and the raw pointer makes it !Send + !Sync
pub struct Config { secret: *const u8 }
```

### Don't derive `Copy` on public types lightly

`Copy` is part of your public contract and almost impossible to remove later: adding a `String` or any non-`Copy` field is a *breaking change* for every caller relying on implicit copies. `Clone` makes the cost explicit at each call site and never changes move semantics, so promise `Clone` freely and reserve `Copy` for types guaranteed to stay trivially copyable forever.

```rust
// Idiomatic — safe to evolve
#[derive(Clone)]
pub struct Handle { id: u64, name: String }

// Risky — adding a non-Copy field later breaks callers
#[derive(Clone, Copy)]
pub struct Handle { id: u64 }
```

## Keep traits object-safe by default

Whether a trait can be used as `dyn Trait` is an implicit part of its contract, and callers will reach for trait objects you never anticipated. Keep the trait object-safe, and where a method *can't* be (it's generic or returns `Self`), gate that one method with `where Self: Sized` instead of poisoning the whole trait. `Iterator` and `Read` do exactly this.

```rust
// Idiomatic — object-safe trait with an opt-out convenience method
pub trait Processor {
    fn run(&self, data: &[u8]);
    fn run_all(self) where Self: Sized { /* ... */ }
}

// Avoid — a generic method makes the entire trait non-object-safe
pub trait Processor {
    fn run<T: Debug>(&self, data: T);
}
```

## Reduce signature noise with type aliases

When a concrete type repeats across a module — especially `Result<T, SpecificError>` — a type alias removes the clutter from every signature while preserving all methods and the `?` operator of the underlying type. It also lets you present one consistent error type as your module's interface.

```rust
// Idiomatic
type Result<T> = std::result::Result<T, std::io::Error>;
fn write(&mut self, buf: &[u8]) -> Result<usize>;

// Avoid
fn write(&mut self, buf: &[u8]) -> std::result::Result<usize, std::io::Error>;
```

## Mark return values `#[must_use]` only when ignoring them is a bug

`#[must_use]` is why ignoring a `Result` warns — discarding an error is almost always wrong. Apply it to guards, builders that must be consumed, and other returns whose loss is a near-certain mistake. Slapping it on ordinary value-returning functions (`to_uppercase`) just trains users to ignore the warning.

```rust
// Idiomatic — dropping the guard would release the lock immediately
#[must_use]
pub fn acquire_lock(&self) -> LockGuard<'_> { /* ... */ }

// Avoid — noise; ignoring the result here is harmless
#[must_use]
pub fn to_uppercase(&self) -> String { /* ... */ }
```

## Design the API before the internals

Write the call site you wish existed, then let `cargo check` errors drive the implementation. Designing the API first guarantees signatures fit how callers actually want to use the type; bolting an API onto finished internals tends to leak implementation details into awkward signatures.

```rust
// Sketch the desired usage first, then implement to satisfy the compiler.
let pool = ThreadPool::new(4);
pool.execute(|| handle_connection(stream));
```

## Operator overloading: only when algebra is natural

Overload operators only for types where `+`, `-`, `*` carry an obvious mathematical meaning, and implement a coherent set rather than a single operator. A type with `Add` and `Neg` but no `Sub` leaves `x - y` and `x + (-y)` with different (or missing) behavior — a violation of least astonishment that C++ experience shows breeds unmaintainable, surprising code. If the operators don't model real algebra, use named methods instead.

```rust
// Idiomatic: Vector2 implements Add, Sub, Neg, and Mul<f32> — a closed, consistent set.
// Avoid: implementing Add but not Sub, so x + (-y) != x - y.
```

## Log through a facade, depend on small composable crates

Library code must never hard-wire a logger or `println!` for diagnostics. Emit through the `log` facade (`log::info!`) — it produces nothing until the *binary* installs a backend, leaving the choice to the consumer. Wire up `env_logger` in `main` and tune per-crate levels through `RUST_LOG` (e.g. `info,trust_dns_proto=error`) with no recompile.

```rust
// In the library
log::info!("scanning: {target}");

// In the binary's main
std::env::set_var("RUST_LOG", "info,trust_dns_proto=error");
env_logger::init();

// Avoid in library code — forces a logging style on every consumer
println!("[INFO] scanning: {target}");
```

The same composability principle governs dependencies: favor focused crates (`reqwest`, `hyper`, `tokio`, `rustls`) that compose cleanly over monolithic frameworks that re-export everything. Smaller surfaces mean faster builds, auditable dependency trees, and the freedom to swap one layer without rewriting the rest.
