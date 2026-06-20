# Ownership & Borrowing

Write Rust that moves, borrows, and clones deliberately so the borrow checker becomes a guide rather than an obstacle.

## Moves vs. copies vs. clones

Assigning a heap-owning type (`String`, `Vec<T>`, `Box<T>`) **moves** ownership: the source binding is invalidated to prevent a double-free, and using it afterward is a compile error (E0382). This is not a shallow copy — there is exactly one owner at a time.

Stack-only types that implement `Copy` (integers, `bool`, `char`, tuples of `Copy` types) are bitwise-copied on assignment instead, so the source stays valid. A type can never be both `Copy` and `Drop`. Calling `.clone()` on a `Copy` type is redundant and misleading.

Rust never deep-copies implicitly. `.clone()` is the explicit, visible signal that a heap allocation is happening — treat every `.clone()` as a cost at the call site, not punctuation.

```rust
// Idiomatic
let n: i32 = 5;
let m = n;              // Copy: n still valid
let s2 = s1.clone();   // explicit deep copy when truly needed

// Avoid
let m = n.clone();     // redundant; i32 is Copy
let s2 = s1;           // looks like a copy, actually moves s1 (now dead)
```

Do not assume a custom type copies just because primitives did. Integers and `bool` implement `Copy` and silently duplicate on pass-by-value, but a `struct`/`enum` you define **moves** unless you opt in with `#[derive(Copy, Clone)]`. Expecting copy semantics on your own type is the classic source of surprise E0382 errors.

## Borrow instead of moving

When a function only needs to read or temporarily mutate a value, pass a reference (`&T` / `&mut T`) so the caller keeps ownership. Taking ownership forces the caller to surrender the value permanently or hand it back through an awkward return tuple. References are immutable by default; reach for `&mut` only when the callee must mutate.

```rust
// Idiomatic: take &str, not &String — accepts String, &str, and literals alike
fn calculate_length(s: &str) -> usize { s.len() }
io::stdin().read_line(&mut guess);

// Avoid
fn calculate_length(s: String) -> (String, usize) {
    let len = s.len();
    (s, len)           // hand the value back just so the caller can reuse it
}
```

Passing a non-`Copy` value into a function moves it; the caller cannot use it afterward. Plan the ownership transfer or borrow instead. If a function genuinely needs *temporary* exclusive ownership (e.g. to thread a value through a builder), the deliberate pattern is to return it back and rebind at the call site — but borrowing is almost always simpler than the return-and-rebind dance.

Prefer short-lived, locally-created values over long-lived globals or singletons. A single large object kept alive for the whole program makes it hard to take multiple disjoint borrows from different places; constructing values on demand and transferring ownership freely composes better with the borrow checker.

## Iterate by reference, not by move

A bare `for x in collection` calls `into_iter()`, which **moves** the collection — the binding is dead after the loop. Iterate over `&collection` (or `.iter()` / `.iter_mut()`) whenever you need the collection again afterward. The compiler's own fix-it suggests `&collection`.

```rust
// Idiomatic
for item in &haystack { /* ... */ }   // haystack still usable after the loop

// Avoid
for item in haystack { /* ... */ }    // haystack moved; unusable afterward
```

## The borrowing rules

At any given time you may have **either** one `&mut` reference **or** any number of `&` references — never both, and never two `&mut`, to the same value. This is how Rust rules out data races at compile time.

Lifetimes are **regions of code, not lexical scopes**. Under Non-Lexical Lifetimes (NLL) a borrow ends at its *last use*, so a fresh `&mut` is fine once all prior borrows are done — even if the shared-reference variable is still in scope, and even across `if`/`else` branches where the conflicting borrows never coexist on any one control-flow path.

```rust
// Idiomatic
let r = &x;
if cond {
    *x = 84;             // OK: r is never used on this path
} else {
    println!("{r}");     // OK: no mutation conflicts here
}

// Avoid (mental model error)
// Assuming `&x` blocks all mutation of x until end-of-scope. It does not —
// the borrow dies at its last use on each path.
```

A live borrow freezes the borrowed value **and all its owners**. Holding `&v[0]` keeps the whole `Vec` immutable, so calling `v.push(x)` while that reference lives is rejected — a push may reallocate the buffer and dangle the reference. Copy the element out, or finish using the borrow first.

```rust
// Idiomatic
let first = v[0];   // copied out (or .clone() if not Copy)
v.push(6);

// Avoid
let first = &v[0];
v.push(6);          // E0502: reallocation could dangle `first`
println!("{first}");
```

If a borrowing type has a `Drop` impl, its destructor counts as a use, so the borrow lives until end of scope even if you stop mentioning it. Call `drop(x)` to end such a borrow early. Always use the free function `drop(x)`, never `x.drop()` (E0040).

## Never return a dangling reference

A value created inside a function is destroyed when the function returns, so returning a reference to it always dangles. Return the owned value and let the caller decide what to do with it — ownership transfer is safe and free.

```rust
// Idiomatic
fn make_greeting() -> String { String::from("hello") }

// Avoid
fn make_greeting<'a>() -> &'a str {
    let s = String::from("hello");
    s.as_str()        // E0515: returns reference to dropped local
}
```

## Slices over indices

To refer to a sub-part of a `String` or array, return a slice (`&str`, `&[T]`) rather than a bare index. An index is logically tied to its source but has no compile-time link, so it silently goes stale if the source mutates. A slice borrows the source, turning invalidation into a compile error.

```rust
// Idiomatic
fn first_word(s: &str) -> &str {
    let bytes = s.as_bytes();
    for (i, &b) in bytes.iter().enumerate() {
        if b == b' ' { return &s[0..i]; }
    }
    &s[..]
}

// Avoid
fn first_word(s: &String) -> usize { /* index can go stale after mutation */ }
```

To mutably borrow two disjoint slice elements at once, use `split_at_mut` rather than indexing twice — the borrow checker cannot prove two indices are distinct, but `split_at_mut` hands back two non-overlapping `&mut` slices safely.

```rust
let (left, right) = data.split_at_mut(2);
left[0] = 10;
right[0] = 20;
```

## Collections take ownership

Inserting an owned value into a `HashMap` (or `Vec`) moves it; you cannot use the original afterward. Insert references only when the referenced data is guaranteed to outlive the collection.

```rust
map.insert(field_name, field_value);
// field_name and field_value are moved — no longer usable
```

## Avoid needless clones

Do not `collect()` an iterator into a `Vec` just to pass a slice when the callee could consume the iterator directly — that forces an allocation and often per-element clones. Accept `impl Iterator<Item = T>` and let the callee move items into its own structures.

```rust
// Idiomatic
Config::build(env::args());
pub fn build(mut args: impl Iterator<Item = String>) -> Result<Config, &'static str> { /* ... */ }

// Avoid
let args: Vec<String> = env::args().collect();
Config::build(&args);   // build() must then clone args[1], args[2]
```

To accept owned values and references interchangeably without forcing callers to borrow or clone, bound on `Borrow<T>` (it has a blanket impl for both `T` and `&T` — the pattern `HashMap::get` uses for keys).

```rust
fn add_four<T: std::borrow::Borrow<i32>>(v: T) -> i32 { v.borrow() + 4 }
add_four(2);    // owned
add_four(&2);   // borrowed
```

When a function *sometimes* needs to own its result and sometimes can return the input untouched, return `Cow<'_, T>` instead of unconditionally allocating. It borrows on the no-op path and allocates only when it must transform — the same flexibility without a heavier signature.

```rust
// Idiomatic: allocates only when the bytes aren't valid UTF-8
fn process(input: &[u8]) -> Cow<'_, str> { String::from_utf8_lossy(input) }

// Avoid: forces an owned String even when no replacement was needed
fn process(input: &[u8]) -> String { String::from_utf8_lossy(input).into_owned() }
```

Reader adaptors like `.take(n)` consume `self`. Calling `reader.by_ref()` first hands `take` a `&mut` adapter, so the underlying reader stays usable for later seeks/reads instead of being moved away.

```rust
// Idiomatic: f survives for subsequent reads
f.by_ref().take(len as u64).read_to_end(&mut data)?;

// Avoid: moves f into take(); f is gone afterward
f.take(len as u64).read_to_end(&mut data)?;
```

## Choosing Copy vs. Clone

`Copy` is always implicit and always a bit-for-bit duplication, so only derive it for cheap, trivially-duplicable types (plain integer wrappers, small POD structs). Never put `Copy` on a heap-owning type like `struct B { data: Vec<u8> }` — a bitwise copy would alias the heap buffer and create two owners (a double-free waiting to happen); use `Clone` for any non-trivial or expensive duplication. `Clone` is a supertrait of `Copy` (`trait Copy: Clone`), so every `Copy` type must also be `Clone` — derive both together: `#[derive(Copy, Clone)]`. Deriving `Copy` alone is a compile error. (Consequently `T: Copy` always implies `T: Clone`.)

```rust
// Idiomatic: cheap, no heap
#[derive(Copy, Clone, Debug)]
struct SatId(u64);

// Avoid: Copy on heap-owning data is unsound
#[derive(Copy, Clone)]
struct BigBuffer { data: Vec<u8> }   // does not compile, and shouldn't
```

## Move closures across threads

Pass a `move` closure to `thread::spawn`. The thread may outlive the scope that defined the closure, so it must own its captures rather than borrow into a stack frame that could be dropped first; the compiler rejects the borrowing form (it requires `'static` captures).

```rust
// Idiomatic
thread::spawn(move || println!("{list:?}")).join().unwrap();

// Avoid
thread::spawn(|| println!("{list:?}")).join().unwrap();   // may outlive borrowed `list`
```

## Lifetimes as they relate to ownership

Prefer types that **own** their contents over types that store references. Every reference field forces a lifetime parameter onto the struct, which then infects every containing type. Reserve borrowed fields for cases where performance genuinely demands it.

```rust
// Idiomatic: owns its data, no lifetime parameter
struct Record { index: usize, item: Item }

// Borrowed form needs a lifetime that propagates outward
struct ReferenceHolder<'a> { index: usize, item: &'a Item }
```

When a lifetime is elided but present (e.g. a function returning `ReferenceHolder`), write the anonymous lifetime `'_` so the borrow relationship stays visible: `fn find_one(items: &[Item]) -> ReferenceHolder<'_>`.

Avoid self-referential structs — a struct can move in memory, dangling any reference that points inside itself. Store byte-range offsets (`Range<usize>`) instead of internal slices; reach for `Pin` or the `ouroboros` crate only if truly unavoidable.

```rust
// Idiomatic: offsets never dangle across a move
struct Section { text: String, title: Option<std::ops::Range<usize>> }
```

### Use multiple lifetime parameters when outputs tie to one input

Give a type more than one lifetime parameter when its methods return a reference tied to **exactly one** of its stored references. Collapsing them into a single `'a` couples the output's lifetime to the unrelated input, over-constraining every caller. A `StrSplit` that yields slices of the *document* must not have that output lifetime pinned to the *delimiter*.

```rust
// Idiomatic: Item is tied to the document ('s), independent of the delimiter ('p)
struct StrSplit<'s, 'p> { document: &'s str, delimiter: &'p str }
impl<'s, 'p> Iterator for StrSplit<'s, 'p> { type Item = &'s str; /* ... */ }

// Avoid: one lifetime forces Item = &'a str, coupling output to the delimiter
struct StrSplit<'a> { document: &'a str, delimiter: &'a str }
```

### Variance: `&mut T` is invariant in `T`

`&mut T` is **invariant** over `T`, meaning the borrow checker cannot shorten or substitute the inner type's lifetime. So when a struct holds `&'a mut &'b T`, keep `'a` and `'b` as *separate* parameters. Merging them into one applies that invariance to the inner borrow too, and the checker will refuse to shrink it — rejecting otherwise-valid code.

```rust
// Idiomatic: 'a can end independently of 'b
struct MutStr<'a, 'b> { s: &'a mut &'b str }

// Avoid: shared lifetime makes the inner borrow un-shortenable
struct MutStr<'a> { s: &'a mut &'a str }
```

## Practical escape hatches

- **Move out of a `&mut`:** you cannot move a value out from behind a mutable reference — that would leave the location empty and the eventual `drop` would double-free. Use `std::mem::take(slot)` to swap in `Default::default()` and return the old value, `std::mem::swap(a, b)` to exchange two owned values (both slots stay populated), or `std::mem::replace(slot, new)` (also `Option::take`/`replace`) to substitute an explicit value.

  ```rust
  let was = std::mem::take(s);   // s now holds Default::default()
  std::mem::swap(s, &mut other); // both s and other remain valid
  // Avoid: let was = *s;        // E0507: cannot move out of `*s`
  ```

- **`'static` from the heap:** `Box::leak` converts `Box<T>` into `&'static mut T` by abandoning the owner. It satisfies `'static` but permanently leaks the memory — a deliberate one-time escape hatch, not a pattern.

- **Diagnosing borrow errors:** break a long chained expression into `let` bindings with explicit type annotations to pin the error to the exact failing conversion. Bind a temporary to a named `let` to extend its lifetime past the end of the statement when a reference must outlive a single expression.

- **Drop ordering:** struct fields drop in declaration order, but relying on that is fragile. When order matters, wrap fields in `ManuallyDrop` and drop them explicitly. A generic `Drop` impl must let its generic arguments strictly outlive the type — the drop checker conservatively rejects destructors that could observe already-dropped borrowed data (use-after-free).
