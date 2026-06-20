# Collections & Iterators

Write idiomatic Rust over `Vec`, `HashMap`, `String`, and iterators: prefer iterator chains and the entry API over manual index bookkeeping.

## Iterating without indices

A bare `for` loop is bounds-safe and eliminates off-by-one bugs and stale-length checks. Index-based `while` loops force you to manage the counter and the bound by hand. Iterate the collection directly.

```rust
// Idiomatic
for element in &v {
    println!("{element}");
}
for element in &mut v {
    *element += 50;
}

// Avoid
let mut i = 0;
while i < v.len() {
    println!("{}", v[i]);
    i += 1;
}
```

For countdowns use a reversed range instead of a manual decrement: `for n in (1..4).rev()`.

Direct iteration also lets the compiler prove every access is in-bounds and elide bounds checks; `collection[i]` in a `0..len` loop pays for a check on every access and opens a window where the length could change mid-loop.

### enumerate over a manual counter

When you need the index, use `enumerate()` rather than a separate mutable counter. The bookkeeping lives inside the iterator protocol where it can't be forgotten or mis-incremented.

```rust
// Idiomatic
for (i, line) in quote.lines().enumerate() {
    println!("{}: {}", i + 1, line);
}

// Avoid
let mut n = 1;
for line in quote.lines() {
    println!("{}: {}", n, line);
    n += 1;
}
```

### Borrow vs. consume

A bare `for item in collection` calls `into_iter()` and *moves* the collection, leaving it unusable afterward. Prefix with `&` (or call `.iter()`) to borrow; iterate the bare value only when consuming it is intentional.

```rust
// Idiomatic — collection survives the loop
for item in &collection {
    println!("{}", item.0);
}
println!("{collection:?}"); // still valid

// Avoid — value moved, won't compile below
for item in collection { /* ... */ }
println!("{collection:?}"); // error: value moved
```

Pick the iterator deliberately:
- `iter()` — immutable references (`&T`), collection intact.
- `iter_mut()` — mutable references (`&mut T`) for in-place edits.
- `into_iter()` — owned values, consumes the collection (avoids clones when transferring ownership is acceptable).

## Indexed access: panic vs. recover

`&v[i]` panics on out-of-bounds. Use `v.get(i)` when the index may legitimately be out of range (user input, parsing) so the caller can recover via the returned `Option<&T>`.

```rust
// Idiomatic — recoverable
match v.get(index) {
    Some(val) => println!("{val}"),
    None => println!("index out of range"),
}

// Avoid when index is untrusted
let val = &v[index]; // panics if index >= v.len()
```

## Iterator adapters over manual loops

Iterator adapters (`map`, `filter`, `take`, `zip`, `sum`, `collect`, ...) express intent at a higher level, drop mutable accumulator state, and are zero-cost: they compile to the same assembly as hand-written loops (sometimes better, e.g. the compiler can skip bounds checks because each element is known in range). Prefer them for simple pipelines.

```rust
// Idiomatic
let results: Vec<_> = contents
    .lines()
    .filter(|line| line.contains(query))
    .collect();

let even_sum_squares: u64 = values
    .iter()
    .filter(|x| *x % 2 == 0)
    .take(5)
    .map(|x| x * x)
    .sum();

// Avoid
let mut results = Vec::new();
for line in contents.lines() {
    if line.contains(query) {
        results.push(line);
    }
}
```

**Adapters are lazy.** They do nothing until a *consuming* adapter (`collect`, `sum`, `for_each`, ...) drives the chain. Leaving `v.iter().map(...)` unconsumed produces an `unused_must_use` warning and has no effect.

```rust
let v2: Vec<_> = v1.iter().map(|x| x + 1).collect(); // good
v1.iter().map(|x| x + 1);                            // warning: unused `Map`
```

### filter_map over filter + map

When the mapping is fallible or returns `Option`, use `filter_map`: it runs in a single pass and consumes `Option`-returning calls (`parse`, checked arithmetic, fallible lookups) directly, instead of nesting `if let`/`match` inside a closure or chaining a separate `filter`.

```rust
// Idiomatic — one pass, drops the Nones
let positives: Vec<i64> = strings
    .into_iter()
    .filter_map(|s| s.parse::<i64>().ok())
    .filter(|&n| n > 0)
    .collect();

// Avoid — mutable accumulator + nested conditionals
let mut positives = Vec::new();
for s in &strings {
    if let Ok(n) = s.parse::<i64>() {
        if n > 0 { positives.push(n); }
    }
}
```

### flatten nested iterators instead of nested loops

To produce one flat collection from a per-item sub-sequence, map each item to its sub-iterator and `flatten()` (or use `flat_map`) rather than a nested `for` with a shared mutable target. Combines naturally with `collect()` into a `HashSet`/`Vec` for dedup-and-filter pipelines.

```rust
let subdomains: HashSet<String> = entries
    .into_iter()
    .flat_map(|e| e.name_value.split('\n').map(str::trim).map(String::from).collect::<Vec<_>>())
    .filter(|s| s != target && !s.contains('*'))
    .collect();
```

### fold vs reduce

Use `reduce` when the accumulator and item types match (sum, product, min). Use `fold` when the output type differs from the item type — e.g. accumulating `&str` items into a `String`, or items into a struct — because `reduce` can't change the type and returns `Option<Item>`.

```rust
let sentence = words.iter().fold(String::new(), |acc, w| acc + w); // &str items -> String
let total = nums.iter().copied().reduce(|a, b| a + b);             // Option<i32>, same type
```

### When to keep an explicit loop

Iterator transforms win for *simple* pipelines. When the body is large, multi-purpose, or has complex early-exit / error logic that doesn't map cleanly to `try_for_each` or `collect::<Result<_>>()`, an explicit loop is clearer. Don't force an awkward closure.

## collect into Result and propagate errors

`collect::<Result<Vec<_>, _>>()` short-circuits on the first `Err`, so you can propagate with `?` instead of unwrapping (and panicking) inside the closure.

```rust
// Idiomatic — first error propagates to caller
let result: Vec<u8> = inputs
    .into_iter()
    .map(|v| u8::try_from(v))
    .collect::<Result<Vec<_>, _>>()?;

// Avoid — panics on bad input
let result: Vec<u8> = inputs
    .into_iter()
    .map(|v| u8::try_from(v).unwrap())
    .collect();
```

## Closures: defer fallback work

`unwrap_or` evaluates its argument eagerly even when the `Option` is `Some`. `unwrap_or_else` takes a closure called only on `None`, so it skips wasted work and can capture the environment.

```rust
user_preference.unwrap_or_else(|| self.most_stocked()); // called only when None
user_preference.unwrap_or(self.most_stocked());         // always runs most_stocked()
```

## Implementing a custom iterator

The `Iterator` trait requires only `next()`. Every adapter (`map`, `filter`, `sum`, `collect`, ...) comes free via default implementations, so a custom iterator gains the full API immediately.

```rust
impl Iterator for Counter {
    type Item = u32;
    fn next(&mut self) -> Option<u32> { /* ... */ }
    // map, filter, sum, collect — all free
}
```

## Reading input as an iterator

Prefer `BufReader::lines()` over a manual `read_line()` loop. The manual form needs a reused `String` buffer, an explicit `buf.clear()` after each line (easy to forget — otherwise lines accumulate), and a zero-length check for EOF. `lines()` yields `Result<String>` and strips the trailing newline for you.

```rust
// Idiomatic
let reader = BufReader::new(File::open(path)?);
for line in reader.lines() {
    let line = line?;
    println!("{line}");
}

// Avoid — manual buffer, clear, EOF check
let mut line = String::new();
loop {
    let len = reader.read_line(&mut line)?;
    if len == 0 { break; }
    print!("{line}");
    line.clear(); // forget this and lines pile up
}
```

## HashMap: the entry API

`entry()` is the idiomatic way to conditionally insert: it avoids a redundant `contains_key` lookup and is borrow-checker-friendly.

```rust
// Insert only when absent
scores.entry(String::from("Yellow")).or_insert(50);

// Update based on previous value — or_insert returns &mut V
let count = map.entry(word).or_insert(0);
*count += 1;
```

`get` returns `Option<&V>`. For `Copy` values, `.copied()` yields `Option<V>`, pairing cleanly with `.unwrap_or` for a default without a manual deref.

```rust
let score = scores.get(&team_name).copied().unwrap_or(0); // good
let score = *scores.get(&team_name).unwrap();             // panics if absent
```

## HashMap vs BTreeMap

Default to `HashMap` for O(1) average lookup. Reach for `BTreeMap` only when you need keys in sorted order or `.range()` queries — its tree structure costs higher constant factors per operation, so picking it "to be safe" is a needless tax.

```rust
let index: HashMap<ByteString, u64> = HashMap::new();      // unordered lookups
let mut voc: BTreeMap<u32, &str> = BTreeMap::new();        // need ordered/range scans
for (_k, v) in voc.range(0..500_000) { print!("{v} "); }
```

## Vec capacity

`Vec::new` starts at capacity zero and reallocates as it grows. When the final size is known up front, `Vec::with_capacity(n)` allocates exactly once — meaningful for large or hot-path collections.

```rust
let mut workers = Vec::with_capacity(size);
for id in 0..size {
    workers.push(Worker::new(id)); // no reallocation
}
```

`with_capacity(n)` reserves space but leaves `len() == 0`; only use it where you'll *push* the elements in. APIs that read into a buffer (`recv_from`, `read`) inspect `len()`, not capacity — hand them `vec![0; n]`, which sets both length and capacity, or the call sees a zero-length slice and reads nothing.

```rust
let mut request_buf: Vec<u8> = Vec::with_capacity(512); // encoder pushes bytes in
let mut response_buf: Vec<u8> = vec![0; 512];           // recv_from reads len() bytes
socket.recv_from(&mut response_buf)?;
```

`Vec` never shrinks its allocation on its own. After a bulk removal whose smaller size is the new steady state, call `shrink_to_fit()` to hand the excess capacity back to the allocator; otherwise the old buffer is held indefinitely.

```rust
self.particles.retain(|p| p.alive);
self.particles.shrink_to_fit(); // reclaim freed capacity
```

## Strings

`String` does not implement `Index<usize>`: a byte index can't reliably map to a Unicode scalar value, so Rust refuses to return a possibly meaningless byte. Iterate instead.

```rust
for c in "Зд".chars() { println!("{c}"); } // Unicode scalar values
for b in "Зд".bytes() { println!("{b}"); } // raw bytes
let h = s[0];                              // compile error
```

Range slicing (`&s[0..4]`) works on *byte* offsets and **panics at runtime** if a bound falls inside a multi-byte character. Slice only when you know the indices sit on character boundaries.

For appending and concatenation:
- `push_str` takes a `&str`, so the source stays usable: `s1.push_str(s2);` leaves `s2` valid.
- Prefer `format!` over chained `+`. The `+` operator moves its left operand and only accepts `&str` on the right, making chains verbose and ownership-confusing. `format!` borrows every argument and moves nothing.

```rust
let s = format!("{s1}-{s2}-{s3}"); // good
let s = s1 + "-" + &s2 + "-" + &s3; // moves s1, verbose
```

Build strings or transformed `Vec`s with `map(...).collect()` rather than a `for` loop with `push`: the functional form is more declarative and gives the compiler more room to elide intermediate allocations.

```rust
let steps: Vec<Operation> = input.bytes().map(|b| match b {
    b'0' => Home,
    b'1'..=b'9' => Forward((b - 0x30) as isize * SCALE),
    _ => Noop(b),
}).collect();
```
