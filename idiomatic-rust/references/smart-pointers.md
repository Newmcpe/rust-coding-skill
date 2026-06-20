# Smart Pointers

Choosing Box, Rc/Arc, RefCell/Cell, Weak, Deref, and Drop to model ownership, sharing, and mutability correctly.

## Choosing a pointer

Pick the lightest type that expresses your real ownership and mutability needs. Default to single ownership and compile-time borrow checking; add sharing and interior mutability only when the data structure genuinely requires them.

- `Box<T>` — single owner, heap allocation, compile-time borrow checks, zero overhead.
- `Rc<T>` — shared ownership, single-threaded, immutable access only.
- `Arc<T>` — shared ownership across threads (atomic refcount).
- `RefCell<T>` / `Cell<T>` — interior mutability with runtime checks, single-threaded.
- `Mutex<T>` / `RwLock<T>` — interior mutability across threads.
- `Weak<T>` — non-owning reference that breaks cycles.

Common compositions: `Rc<RefCell<T>>` for shared mutable data in one thread; `Arc<Mutex<T>>` (or `Arc<RwLock<T>>` when reads dominate) for the multi-threaded equivalent. `Rc`/`RefCell` are not `Send`/`Sync`, so the compiler rejects them across threads — choose `Arc`/`Mutex` up front to avoid a costly refactor. Prefer `Rc` over `Arc` when you stay single-threaded: `Arc` pays for atomic increments on every clone that `Rc` does not.

A reference-counted pointer is also the idiomatic alternative to threading lifetime parameters through every signature. When data must outlive a scope or have several owners, `Rc`/`Arc` expresses that intent and lets the compiler enforce safety, rather than contorting APIs with `fn process<'a>(c: &'a Config, s: &'a mut State<'a>)`.

The nesting order encodes meaning precisely: `Rc<RefCell<Vec<T>>>` shares one mutable vector; `Rc<Vec<RefCell<T>>>` shares a fixed vector whose elements mutate independently. Choose the layout that matches the invariant you want.

## Box: heap allocation and known size

Use `Box<T>` to give a recursive type a known size, or to move a value to the heap so it can outlive the current scope. A `Box` is a fixed-size pointer regardless of what it points to, which breaks the infinite-size cycle in self-referential enums.

```rust
// Idiomatic: pointer indirection gives the type a finite size
enum List {
    Cons(i32, Box<List>),
    Nil,
}

// Avoid: recursive type has infinite size (E0072)
enum List {
    Cons(i32, List),
    Nil,
}
```

### Box::leak for program-lifetime values

Use `Box::leak` to turn a heap allocation into a `&'static T` without unsafe code, for read-only config or lookup tables that must outlive every scope. This suits values you cannot compute in a `const`/`static` initializer. The allocation is never freed, so leak exactly once at startup — not per request.

```rust
let config: &'static Config = Box::leak(Box::new(load_config()));
```

### Box::pin for oversized async futures

An async state machine accumulates all state live across its await points, including awaited sub-futures, so a deep future can be kilobytes that get `memcpy`'d on every move through structs and call sites. If a profile shows that copying dominates, `Box::pin` the future so only the pointer moves, trading one allocation for the copies. Measure first — do not box reflexively.

```rust
let f: Pin<Box<dyn Future<Output = ()>>> = Box::pin(large_async_fn());
f.await;
```

## Interior mutability: prefer compile-time checks

`RefCell<T>` (and `Cell<T>`) move borrow enforcement to runtime, so a double `borrow_mut()` panics instead of failing to compile. Treat them as a targeted tool, not a default — reflexive `Rc<RefCell<T>>` everywhere trades away Rust's core aliasing guarantees and hides bugs until runtime. Where you can restructure data so one collection owns values and another indexes by key, prefer that.

The legitimate use is when a trait forces `&self` but the implementation must record state — for example mock objects:

```rust
// Idiomatic: &self receiver mutates internal state via RefCell
struct MockMessenger {
    sent: RefCell<Vec<String>>,
}
impl Messenger for MockMessenger {
    fn send(&self, msg: &str) {
        self.sent.borrow_mut().push(msg.to_string());
    }
}
```

`Rc`/`Arc` only hand out shared `&T`, so mutating shared data *requires* an interior-mutability cell inside — `shared.push(1)` on an `Rc<Vec<_>>` will not compile. The composition runs two runtime mechanisms (refcount plus borrow/lock), so you pay the cost twice; know that before reaching for it.

```rust
let value = Rc::new(RefCell::new(5));
*value.borrow_mut() += 10;
```

Keep each `borrow_mut()` guard in the tightest scope possible. A live `RefMut` aliased by a second `borrow_mut()` panics at runtime, so drop the first guard (end its block) before taking the next.

```rust
// Idiomatic: guard dropped before the next borrow
{
    let mut inner = cell.borrow_mut();
    inner.freq -= 12.34;
}
let mut inner2 = cell.borrow_mut();

// Avoid: two live mutable borrows — panics
let mut a = cell.borrow_mut();
let mut b = cell.borrow_mut(); // already mutably borrowed
```

That said, do not contort signatures with many lifetime parameters just to avoid reference counting. `Arc<Mutex<T>>` can be the clearest model for shared mutable state — reach for it deliberately, not only as a last resort.

## Rc/Arc: shared ownership and clone semantics

Call the associated function `Rc::clone(&a)` (or `Arc::clone`) rather than `a.clone()`. It only increments the reference count — cheap, not a deep copy — and the explicit form signals that during a performance audit.

```rust
// Idiomatic: clearly a refcount bump
let b = Rc::clone(&a);

// Avoid: reads like an expensive deep clone
let b = a.clone();
```

### Arc for shared application state

Share immutable application state across async handlers with `Arc<AppState>`, and pass the pool/service through function parameters rather than a global `static`. `Arc` gives cheap multi-owner sharing across tasks without a hidden dependency, and explicit parameters stay testable.

```rust
// Idiomatic: state passed in, dependency visible
let app_state = Arc::new(AppState::new(service));

pub async fn create_job(
    state: Arc<AppState>,
    input: CreateJob,
) -> Result<impl warp::Reply, warp::Rejection> { /* ... */ }

// Avoid: hidden global dependency
static DB: Lazy<Pool<Postgres>> = Lazy::new(|| /* ... */);
```

## Cow: borrow until you must own

Use `Cow<str>` / `Cow<[T]>` when reading from an external buffer (FFI, file, network) where most paths only read. `Cow` holds either a borrow or an owned value, so it allocates a fresh `String`/`Vec` only when a mutation actually demands it — not just to satisfy the type system.

```rust
// Idiomatic: no allocation when the input is already valid
let c: Cow<str> = unsafe { CStr::from_ptr(c_ptr) }.to_string_lossy();
println!("{c}");

// Avoid: eager owned copy you never mutate
let s: String = some_cstr.to_string_lossy().into_owned();
```

## Weak: break reference cycles

`Rc`/`Arc` cycles keep strong counts above zero forever, leaking memory; Rust does not detect them. Model ownership to match lifetimes: parents own children with `Rc<T>`, children point back with `Weak<T>`. A `Weak` does not raise the strong count, so it never keeps its target alive.

```rust
// Idiomatic: owning down, non-owning back-reference up
struct Node {
    parent: RefCell<Weak<Node>>,
    children: RefCell<Vec<Rc<Node>>>,
}

// Avoid: parent <-> child both owning — never freed
struct Node {
    parent: RefCell<Rc<Node>>,
    children: RefCell<Vec<Rc<Node>>>,
}
```

A `Weak` may already be dead, so always `upgrade()` and handle `None`:

```rust
if let Some(parent) = leaf.parent.borrow().upgrade() {
    // use parent
}
```

## Deref: make custom pointers transparent

Implement `Deref` (and `DerefMut`) so a custom pointer behaves like a reference: it enables `*` and deref coercion. Coercion chains are resolved at compile time with zero runtime cost, so prefer it over manual `*&` juggling.

```rust
use std::ops::Deref;
impl<T> Deref for MyBox<T> {
    type Target = T;
    fn deref(&self) -> &T {
        &self.0
    }
}

// Coercion: &MyBox<String> -> &String -> &str, automatically
hello(&m);
```

For a custom contiguous buffer, deref to a slice (`Deref<Target=[T]>` + `DerefMut`) to inherit the entire slice API — `len`, indexing, `iter`, `sort`, `binary_search` — without re-implementing any of it.

## Drop: deterministic, RAII-style cleanup

Implement `Drop` to tie resource release (file descriptors, locks, raw memory, threads) to value lifetime. The compiler runs `drop` automatically at scope exit on every control-flow path, so early returns and panics cannot skip cleanup the way a manual call can. Conversely, never manually `close()` a `File`/socket/handle — let the owner drop. Manual teardown is redundant and adds error-path leak/double-free bugs.

```rust
impl Drop for ThreadPool {
    fn drop(&mut self) {
        drop(self.sender.take());
        for worker in &mut self.workers {
            if let Some(thread) = worker.thread.take() {
                thread.join().unwrap();
            }
        }
    }
}
```

Force early cleanup with `drop(value)` (the prelude `std::mem::drop`), never `value.drop()` — calling the destructor method directly is rejected (E0040) to prevent double frees.

`Drop::drop` takes `&mut self`, returns nothing, and cannot `.await`, so it can neither propagate errors nor do async teardown. For fallible or async cleanup, expose a consuming method that takes `self` and returns `Result` (or is `async fn`); keep `Drop` as a best-effort fallback that swallows errors.

```rust
// Idiomatic: graceful path returns the error; Drop is best-effort
impl Connection {
    pub async fn close(self) -> Result<(), Error> { /* flush, shutdown */ Ok(()) }
}
impl Drop for Connection {
    fn drop(&mut self) {
        let _ = self.try_close_sync();
    }
}

// Avoid: unwrap in Drop turns a cleanup error into a panic mid-unwind
impl Drop for Connection {
    fn drop(&mut self) {
        self.flush().unwrap();
    }
}
```

### Move a field out from behind `&mut`

You cannot move a field out of a borrowed struct. Wrap it in `Option<T>` and call `.take()` to swap in `None` and gain ownership of the inner value — the standard pattern for joining a thread or transitioning state in `Drop` or `&mut self` methods.

```rust
struct Worker {
    thread: Option<thread::JoinHandle<()>>,
}
if let Some(thread) = worker.thread.take() {
    thread.join().unwrap();
}
```

## Buffer writes to batch syscalls

Each `write()` on a raw `File` can become a syscall. For many small sequential writes, wrap the writer in `BufWriter` so writes accumulate in a user-space buffer and flush in larger chunks. Hold the `BufWriter` for the burst, then let it drop (or `flush()`) to commit.

```rust
let mut f = BufWriter::new(&mut self.f);
f.write_u32::<LittleEndian>(checksum)?;
f.write_u32::<LittleEndian>(key_len as u32)?;
f.write_all(&tmp)?;
```

## Unsafe smart-pointer internals

When hand-writing a reference-counted pointer:

- Store the inner pointer as `NonNull<T>`, not `*mut T`. It is covariant over `T` and statically non-null, ruling out a class of unsound casts.
- Add `PhantomData<Inner<T>>` so the drop checker knows the type logically owns a `T`; without it, it may permit use-after-free in destructors.
- Never rely on a destructor running to uphold a safety invariant. `mem::forget` is safe and can skip any `Drop`, so design so a skipped destructor leaks at worst — never causes UB.

```rust
pub struct Arc<T> {
    ptr: NonNull<ArcInner<T>>,
    phantom: PhantomData<ArcInner<T>>,
}
```

To measure real heap cost instead of guessing (allocation latency correlates poorly with size), install a `#[global_allocator]` that wraps `System` and times each call. **Footgun:** anything that logs inside `alloc`/`dealloc` (`eprintln!`, `println!`) itself allocates and re-enters the hook — without a guard that recursion deadlocks or overflows the stack. Break it with a thread-local re-entrancy flag.

```rust
use std::cell::Cell;

#[global_allocator]
static ALLOCATOR: ReportingAllocator = ReportingAllocator;

thread_local! { static IN_HOOK: Cell<bool> = const { Cell::new(false) }; }

unsafe impl GlobalAlloc for ReportingAllocator {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let start = Instant::now();
        let ptr = System.alloc(layout);
        IN_HOOK.with(|g| {
            if !g.replace(true) {              // skip logging if we re-entered via eprintln!
                eprintln!("{}\t{}", layout.size(), start.elapsed().as_nanos());
                g.set(false);
            }
        });
        ptr
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        System.dealloc(ptr, layout);
    }
}
```
