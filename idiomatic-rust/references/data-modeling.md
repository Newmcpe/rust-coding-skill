# Data Modeling in Rust

Shape data so the compiler rejects invalid states: structs, enums, pattern matching, newtypes, builders, and `Default`.

## Core principle: make invalid states unrepresentable

Encode invariants in the type system so bad combinations fail to compile instead of slipping through runtime checks or comments that drift out of date.

Attach data to the variant it belongs to. A separate tag-plus-data struct lets the tag and data disagree; an enum cannot.

```rust
// Idiomatic — the data only exists when the variant does
enum Color {
    Monochrome,
    Foreground(RgbColor),
}
struct DisplayProps { x: u32, y: u32, color: Color }

// Avoid — fg_color is meaningless (but still present) when monochrome is true
struct DisplayProps { x: u32, y: u32, monochrome: bool, fg_color: RgbColor }
```

Replace `bool` parameters with enums. A bare `true`/`false` carries no meaning at the call site and lets callers silently transpose arguments; a dedicated enum is self-documenting and the compiler catches swaps. This scales: two `bool`s already give four call sites that look identical and can be transposed unnoticed.

```rust
// Idiomatic
fn print_page(sides: Sides, color: Output) { /* ... */ }
print_page(Sides::Both, Output::BlackAndWhite);

// Avoid
print_page(/* both_sides= */ true, /* color= */ false);
```

Use `Option<T>` for absence — never a sentinel like `-1`, `""`, or null. Rust has no null; `Option` forces every caller to handle the missing case. This applies to struct fields too: model an absent `cwe_id` as `Option<String>`, not an empty string the type system can't see.

```rust
struct Cve { name: String, cwe_id: Option<String>, score: f32 }
fn find_item(list: &[i32]) -> Option<i32> { list.first().copied() }
```

Reserve `Option<Vec<T>>` for when *absence is meaningfully distinct from empty*. Otherwise an empty `Vec` already means "none", and the extra `Option` layer is redundant unwrapping at every use.

```rust
// Idiomatic — empty Vec = none; Option only where presence is its own signal
struct Message { queries: Vec<Query>, answers: Vec<Record>, edns: Option<Edns> }

// Avoid — None and Some(vec![]) mean the same thing
struct Message { queries: Option<Vec<Query>>, answers: Option<Vec<Record>> }
```

When a value carries both `data` and `error`, match *all* combinations exhaustively rather than assuming the happy path. An over-the-wire shape can deliver both-none or both-some; a tuple match forces you to name those impossible-but-receivable states instead of `unwrap`-ing into silent corruption.

```rust
let id = match (res.data, res.error) {
    (Some(d), None) => Ok(d.id),
    (None, Some(e)) => Err(Error::Api(e.message)),
    (None, None)    => Err(Error::Api("data and error both null".into())),
    (Some(_), Some(_)) => Err(Error::Api("data and error both non-null".into())),
}?;
```

## Structs vs tuples

Prefer named-field structs when several values belong together. Tuple indices (`.0`, `.1`) are opaque and easy to transpose; field names document intent and resist swap errors. Returning `(String, String)` loses the relationship — return a named `Config`/`Rectangle` instead.

Use *tuple structs* to make distinct types from identical representations. `Color(i32, i32, i32)` and `Point(i32, i32, i32)` are not interchangeable; the compiler refuses to pass one where the other is expected.

Store owned fields (`String`, not `&str`) by default. Owned data lives as long as the struct does; storing a reference requires a lifetime parameter and ties the struct to a borrow.

Model conceptually-distinct keys as distinct fields even when their types coincide. Separating `identity_key` (long-term signing) from `prekey` (ephemeral key-exchange) into named fields makes accidental reuse a code-review catch; one fused `keypair` hides the lifecycle entirely.

## Construction ergonomics

Provide a `Type::new()` constructor rather than exposing raw struct-literal construction to callers. A literal forces callers to know every field and couples them to internal layout; `new` hides fields, sets defaults, and can enforce invariants. It's also the community convention.

Use field-init shorthand when a parameter name matches its field, and struct-update syntax to copy unchanged fields. Spelling out every field is verbose and silently drops new fields when the struct grows. Note that `..other` *moves* non-`Copy` fields, consuming the source.

```rust
// Idiomatic
fn build_user(email: String, username: String) -> User {
    User { active: true, username, email, sign_in_count: 1 }
}
let user2 = User { email: new_email, ..user1 };
```

Fill the rest with `..Default::default()` when the type derives `Default`. Set only the fields you care about and let the rest default — invaluable for wide C-compatible or FFI request structs where listing every zero-padded optional field is noise.

```rust
let req = SendRawEmailRequest { raw_message: msg, ..Default::default() };
```

## Newtypes

A newtype is a single-field tuple struct. It is zero-cost (elided at compile time) and serves three jobs:

1. **Semantic distinction.** Prefer a newtype over a type alias to attach meaning to a primitive. A `type` alias is transparent — the compiler still treats `PoundForceSeconds` and `NewtonSeconds` as `f64` and happily mixes them. A newtype is a separate type, so unit mismatches are compile errors, and the wrapper can derive its own `Debug`/`Copy`/`PartialEq` and host methods (`Hostname(String)`, `MacAddress([u8; 6])`).

```rust
// Idiomatic — compiler rejects mixing units
struct PoundForceSeconds(f64);
struct NewtonSeconds(f64);

// Avoid — silently interchangeable
type PoundForceSeconds = f64;
type NewtonSeconds = f64;
```

2. **Bypass the orphan rule.** You cannot `impl` a foreign trait for a foreign type. Wrap it in a local newtype and the impl is permitted.

```rust
struct Wrapper(Vec<String>);
impl fmt::Display for Wrapper {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "[{}]", self.0.join(", "))
    }
}
```

3. **Enforced invariants.** Give the field private visibility and a validating constructor. The invariant is checked once, at construction; every consumer can then trust it without re-checking. A newtype wrapping an array (`MacAddress([u8; 6])`) is the place to enforce bit-level invariants and add methods like `is_local()`.

```rust
pub struct Guess { value: i32 }
impl Guess {
    pub fn new(value: i32) -> Guess {
        assert!((1..=100).contains(&value), "Guess must be 1..=100");
        Guess { value }
    }
    pub fn value(&self) -> i32 { self.value }
}
```

When a borrowed/owned split matters but a wrapper is overkill, a *type alias* still earns its keep as documentation — `type ByteStr = [u8]; type ByteString = Vec<u8>` mirrors `str`/`String` and signals intent in signatures without runtime cost.

## Typestate: states as types

When an object moves through states, model each state as its own type rather than a runtime flag. Methods that are invalid in a state simply don't exist on that type, so misuse is a compile error.

Model transitions as methods that consume `self` and return the next type. Taking ownership means the old state cannot be used after the transition.

```rust
// Idiomatic — old state is consumed; DraftPost has no content() to leak unpublished text
impl DraftPost {
    pub fn request_review(self) -> PendingReviewPost {
        PendingReviewPost { content: self.content }
    }
}
impl PendingReviewPost {
    pub fn approve(self) -> Post { Post { content: self.content } }
}

// Avoid — &mut self leaves the stale state usable until the caller stops touching it
impl Post {
    pub fn approve(&mut self) { self.state = /* ... */; }
}
```

For state with no per-state data, encode it as a **marker type parameter** with `PhantomData` and write per-state `impl` blocks. Privileged methods exist only on the authorized type, so calling `run_command` on an unauthenticated connection won't compile — no runtime flag, no panic path.

```rust
struct Unauthenticated;
struct Authenticated;
struct Connection<S> { _state: PhantomData<S> }

impl Connection<Unauthenticated> {
    fn authenticate(self) -> Connection<Authenticated> { /* ... */ }
}
impl Connection<Authenticated> {
    fn run_command(&self, cmd: &str) { /* ... */ }
}
```

## Pattern matching

Use `match` for branching on enum variants. It is exhaustive — the compiler rejects an unhandled variant — making every case visible and preventing forgotten branches. Prefer it over `if/else if` chains even on integers: ranges (`10..=20`), OR-patterns (`40 | 80`), and exhaustiveness all come for free, and adding a variant later breaks every match that forgot it. Avoid a wildcard `_` arm where you *want* that breakage — `_` silently swallows future variants.

```rust
match guess.cmp(&secret) {
    Ordering::Less    => println!("Too small!"),
    Ordering::Greater => println!("Too big!"),
    Ordering::Equal   => println!("You win!"),
}
```

Use `if let` when only one variant matters and exhaustiveness isn't needed — it replaces a `match` with a lone `_ => ()` arm. Use `_` (catch-all) to discard a value and silence the unused-binding warning.

Prefer bare `_` over `_name` when discarding: `_name` still binds and *moves* the value, which can block later use of the original; bare `_` never binds.

```rust
// Avoid — moves s into _s
if let Some(_s) = s { /* ... */ }
println!("{s:?}"); // error: s was moved
```

Destructure in patterns. The shorthand `Point { x, y }` beats `Point { x: x, y: y }`. Combine literals and bindings to test and bind at once, and use `..` to ignore the rest instead of writing `field: _` per field.

```rust
match p {
    Point { x, y: 0 } => println!("on x axis at {x}"),
    Point { x: 0, y } => println!("on y axis at {y}"),
    Point { x, .. }   => println!("x is {x}"),
}
```

Destructure directly in `for` bindings (any irrefutable pattern works):

```rust
for (index, value) in v.iter().enumerate() {
    println!("{value} is at index {index}");
}
```

Use a **match guard** (`if` after a pattern) for conditions a pattern can't express, such as comparing against an *outer* variable — a plain binding would shadow it and always match. Use the **`@` operator** to test a range and capture the value in one step.

```rust
match msg {
    Message::Hello { id: n @ 3..=7 } => println!("in range: {n}"),
    Message::Hello { id }            => println!("other: {id}"),
}
```

## Expression-based assignment

`if`, `match`, and `loop` are expressions — assign their result directly instead of declaring a `mut` binding and writing it from each branch. This removes the chance of forgetting a branch and makes data flow obvious. `loop` yields a value via `break value`.

```rust
// Idiomatic
let description = if is_even(n) { "even" } else { "odd" };
let first = loop { break next()?; };

// Avoid — mutable binding the compiler can't prove is always set sensibly
let mut description;
if is_even(n) { description = "even"; } else { description = "odd"; }
```

## State machines as enums

Model a finite state machine as an enum and drive it with `state = match state { ... }` inside a loop. States as variants make invalid transitions unrepresentable; match guards (`if`) express transition predicates; the loop keeps every transition co-located and exhaustively checked. This beats a tangle of boolean flags and nested `if/else`.

```rust
loop {
    state = match state {
        Http::Connect if !sock.is_active() => { sock.connect(addr)?; Http::Request }
        Http::Request if sock.may_send()   => { sock.send(data)?;     Http::Response }
        Http::Response if !sock.may_recv() => break,
        _ => state,
    };
}
```

## Enums for evolving and heterogeneous data

A `Vec<T>` holds one type. When the set of payload types is closed and known at compile time, wrap them in an enum to store them together with exhaustive handling. If the set is open-ended, use a trait object (`Box<dyn Trait>`) instead.

```rust
enum Cell { Int(i32), Float(f64), Text(String) }
let row: Vec<Cell> = vec![Cell::Int(3), Cell::Text("blue".into())];
```

Give wire-protocol enums an `Unknown(T)` catch-all that preserves the raw value. Protocols evolve; without it, any future or non-standard code fails the whole parse. `Unknown(u16)` keeps forward compatibility and lets callers decide how to handle it. The same trick decouples parsing from policy: a `Noop(u8)` variant carries an unexpected byte forward for logging instead of forcing the parser to error.

```rust
enum RecordType { A, AAAA, /* ... */ Unknown(u16) }
```

Model discrete platform/opcode sets as enums and implement `Display` instead of passing raw strings around — one match centralizes the string mapping, gives `.to_string()` for free, and keeps exhaustiveness checking that stringly-typed code lacks.

When an enum must match an external binary layout (hardware registers, wire opcodes, VGA colors), pin its representation with `#[repr(u8)]` (or the relevant integer type). Bare Rust enum layout is unspecified; `#[repr(u8)]` locks each discriminant to a known byte and, unlike loose `const` values, makes out-of-range colors a compile error.

```rust
#[repr(u8)]
enum Color { Black = 0x0, Cyan = 0x3, White = 0xF }
```

## Traits as part of the model

Give a trait **default method implementations** for behavior expressible in terms of its required methods. Implementors then supply only the essentials and inherit the shared logic, instead of every type re-implementing it.

```rust
trait Enchanter {
    fn competency(&self) -> f64; // required
    fn enchant(&self, thing: &mut Thing) { // provided
        if rand::thread_rng().gen_bool(self.competency()) { /* glow */ }
        else { *thing = Thing::Trinket; }
    }
}
```

## Wire formats and serde

For types crossing a JSON boundary, set the convention once with `#[serde(rename_all = "...")]` rather than annotating each field. Keeps the Rust struct idiomatic, states the rule uniformly, and doesn't rot as fields are added.

```rust
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
struct LoginResponse { ok: bool }
```

Embed compile-time constants (keys, identifiers) as a `&str`/`&[u8]` and parse them fallibly at startup, not as opaque inline byte arrays. The text form stays reviewable in diffs and swappable at build time.

## The builder pattern

Use a builder for structs with many optional fields or fields lacking a `Default`. A struct literal forces every field and is brittle as fields are added; a builder gives a fluent, ergonomic API and centralizes construction.

```rust
DetailsBuilder::new("Robert", "Builder", dob)
    .middle_name("the")
    .preferred_name("Bob")
    .build();
```

Choose the receiver by use case. Consuming (`self`) methods chain fluently but can't build more than once or take conditional steps without re-assignment. Mutable (`&mut self`) methods allow conditional/staged construction but need a named variable first.

```rust
// &mut self builder — conditional step without a move error
let mut b = DetailsBuilder::new(/* ... */);
if informal { b.preferred_name("Bob"); }
let bob = b.build();
```

## Derives

Derive `Debug` on essentially every data type. Rust does not auto-implement it, and `{:?}`/`{:#?}` formatting plus `assert_eq!` failure messages all require it. Use `{:#?}` for pretty multi-line output.

Add `Eq` (and `Hash`) beyond `PartialEq` for `HashMap` keys and `BTreeSet`/`Ord` contexts — these need every value equal to itself, which floats can't guarantee (`NaN`). `HashMap<K, V>` requires `K: Eq + Hash`.

```rust
#[derive(Debug, PartialEq, Eq, Hash)]
struct UserId(u64);
```

`Copy` requires `Clone` (derive both together) and is valid only when every field is stack-only and a bitwise copy is always correct — `String`/`Vec` fields make it impossible. Do implement `Copy` for cheap, trivially-copyable types (e.g. fieldless enums); skipping it makes them awkward. Do *not* implement it where the copy is expensive (a huge array) or semantically wrong, since it silently turns moves into copies.

```rust
#[derive(Copy, Clone, Debug)]
enum Direction { North, South, East, West }
```

## Constants and primitive type choices

Declare program-lifetime values with `const`, not `let`: constants are always immutable, work in any scope, and require a type annotation that documents the value.

```rust
const THREE_HOURS_IN_SECONDS: u32 = 60 * 60 * 3;
```

Annotate a type whenever inference is ambiguous — notably after `.parse()`, which otherwise fails with E0282. Default to `i32` for integers and `f64` for floats; reserve `usize`/`isize` for indexing, where they match the platform pointer width.

```rust
let guess: u32 = "42".parse().expect("not a number");
```

Pick the storage wrapper to match access needs and pay for nothing more: a plain value for stack locals, `Box<T>` for heap indirection, `Rc<T>` for single-threaded sharing, `Arc<Mutex<T>>` only when multiple threads mutate shared state. Reaching for `Arc<Mutex<T>>` by default adds atomic counting and a lock you don't need. For the same reason, prefer flat `Vec`/array layouts over pointer-linked trees: contiguous memory is cache-friendly, while each pointer chase risks a cache miss.

Choose arithmetic semantics explicitly when overflow is possible. Bare `+`/`-` panics in debug and wraps in release; pick `checked_*` (returns `Option`), `saturating_*` (clamps), `wrapping_*` (intentional wrap), or `overflowing_*` (value + flag) so behavior is consistent across profiles. On unsigned types especially, `saturating_sub` avoids underflow panics without a manual bounds check.

```rust
let lower = tag.saturating_sub(ctx_lines); // can't underflow a usize
let (val, overflowed) = a.overflowing_add(b);
```

## Zero-sized and uninhabited types

A zero-sized type (ZST) like `()` carries no data and is fully elided by the compiler. A `HashMap<K, ()>` is exactly how `HashSet<K>` is built — the `()` value costs nothing.

A fieldless struct (`struct Clock;`) is itself a ZST and makes a good **namespace for associated functions** when no state is needed: `Clock::get()` reads as noun-verb, groups related behavior, and leaves room to add state or trait impls later without touching call sites.

```rust
struct Clock;
impl Clock { fn get() -> DateTime<Local> { Local::now() } }
```

The **never type `!`** is the return type for functions that genuinely never return (`exit`, panic handlers, infinite loops). Because `!` coerces to any type, such a call fits any position — the `else` arm of a `match`, a value expression — and the compiler *knows* it diverges. Returning `()` hides that and forces callers to handle a return that can't happen.

```rust
fn exit_process(code: i32) -> ! { unsafe { libc::exit(code) } }
```

An uninhabited type has no values, expressing statically-infallible cases. Prefer the standard `std::convert::Infallible` over a hand-rolled `enum Void {}` — it is what `TryFrom`/`FromStr` use, and conversions to other error types are already implemented for it. `Result<T, Infallible>` advertises that the `Err` arm can never occur, so on Rust 1.82+ (`min_exhaustive_patterns`) callers can destructure it with an irrefutable `let Ok(v) = result;` — the compiler sees the `Err` variant is uninhabited. On older toolchains, use `let Ok(v) = result else { unreachable!() };` or a `match`.

## Drop and shared buffers

Don't manually free, in a `Drop` impl, a resource owned by a field that itself implements `Drop`. Rust recursively drops fields after your `drop` runs, so freeing a field's allocation yourself causes a double-free. Let ownership and recursive drop do the work.

When a collection and its iterator share allocation logic (`ptr`, `cap`, grow/free), extract it into a dedicated `RawVec`-style type that owns the buffer and implements `Drop`. This keeps the deallocation logic in one place and lets each outer type focus on its own invariants.
