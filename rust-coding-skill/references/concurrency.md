# Concurrency

Write data-race-free concurrent Rust: threads, `Send`/`Sync`, channels, and lock discipline that the compiler enforces.

## Spawning threads

`thread::spawn` requires its closure to be `'static`, because the new thread may outlive the scope that created it. Borrowing local data into it is rejected; use a `move` closure to transfer ownership of captured values into the thread, which also satisfies `Send`.

```rust
// Idiomatic
let v = vec![1, 2, 3];
let handle = thread::spawn(move || println!("{v:?}"));
handle.join().unwrap();

// Avoid
let v = vec![1, 2, 3];
thread::spawn(|| println!("{v:?}")); // closure may outlive `v`
```

Keep the `JoinHandle` and `join()` it. When the main thread exits, spawned threads are killed mid-flight regardless of state, so unjoined work is silently lost. `join()` also surfaces a thread's panic as an `Err`.

To join a `Vec<JoinHandle>`, iterate by value (`for h in handles`) or drain with `while let Some(h) = handles.pop()` — `join()` consumes the handle, so iterating by `&` fails with E0507 (cannot move out behind a shared reference).

Keep thread counts at or below the physical core count for CPU-bound work. Threads are not free: each consumes memory and invalidates caches on every context switch, so a spin-loop workload scales near-linearly up to core count and then degrades sharply. Spawning one thread per work item when items number in the thousands is a pessimization — use a fixed-size pool sized to `num_cpus::get()` (or rayon).

## Message passing

Prefer channels (`std::sync::mpsc`) over shared state where you can. Rust eliminates data races but **not** deadlocks; channels sidestep shared-lock ordering entirely, which is the usual deadlock source. Even when state must be shared, reach for a channel before `Arc<Mutex<T>>` for producer-consumer patterns: it eliminates the lock and its contention entirely.

`send` takes ownership of its argument, so using the value afterward is a compile-time use-after-move error — exactly the guarantee that prevents the receiver and sender touching the same value concurrently.

```rust
tx.send(val).unwrap();
// val is moved; touching it here is a compile error
```

Consume the receiver as an iterator instead of a manual `recv()` loop. Iteration yields each message and ends cleanly when all senders are dropped, with no explicit termination branch.

```rust
// Idiomatic
for received in rx {
    println!("Got: {received}");
}

// Avoid
loop {
    match rx.recv() {
        Ok(msg) => println!("{msg}"),
        Err(_) => break,
    }
}
```

For multiple producers, `tx.clone()` once per thread; all clones feed the single receiver. The same `tx` cannot be moved into two threads.

Make the message type an `enum`. It gives exhaustiveness checking, a compact representation, and self-documenting variants — far better than stringly-typed or raw-byte messages that must be parsed and offer no type safety.

```rust
enum Work { Task(Job), Shutdown }
match rx.recv().unwrap() {
    Work::Task(j) => run(j),
    Work::Shutdown => return,
}
```

Signal shutdown with a dedicated message, not a side-channel `AtomicBool` polled in a busy loop. A poison-pill (one `Shutdown` per worker, or dropping the sender so `recv()` returns `Err`) flows through the same channel, preserving ordering and giving deterministic exit. Dropping the sender is idiomatic when you have one consumer; a per-worker sentinel makes intent explicit when you have many.

When workers return results out of order, pre-allocate the result vector and write by index (`results[i] = v`) rather than `push`-ing, which preserves positional correctness with no sort step.

## Shared state: Arc and Mutex

Share ownership across threads with `Arc<T>`, not `Rc<T>`. `Rc` updates its count non-atomically and is not `Send`; `Arc` uses atomic counts and is `Send`. For shared *mutable* state use `Arc<Mutex<T>>`, the thread-safe analogue of `Rc<RefCell<T>>` — `RefCell` is not `Sync` because its runtime borrow checks are not thread-safe.

```rust
// Multi-threaded shared mutability
let counter = Arc::new(Mutex::new(0));
let c2 = Arc::clone(&counter);
thread::spawn(move || *c2.lock().unwrap() += 1);

// Single-threaded shared mutability
let v = Rc::new(RefCell::new(vec![]));
```

Don't mix the two families: `Rc`/`RefCell` are not `Send`/`Sync`, so the compiler stops them at thread boundaries. Pay the `Arc`/`Mutex` synchronization cost only when you actually cross threads. The compiler enforces this: trying to mutate a captured plain variable from two threads is a compile error (E0499/E0502), not a runtime race — `Arc<Mutex<T>>` is how you make the shared mutation legal.

Avoid `static mut`; reading or writing it needs `unsafe` and races under concurrent access. Use a `static COUNTER: Mutex<u32> = Mutex::new(0)` or an atomic instead.

## Lock discipline

`Mutex<T>` wraps the data rather than sitting beside it, so the only way to reach the inner value is to `lock()` first; the returned `MutexGuard` releases the lock via `Drop` when it goes out of scope. Exploit that scope to hold locks for as little time as possible — long critical sections increase contention.

```rust
// Idiomatic — guard dropped at the inner brace, before unrelated work
fn add(&self, delta: i32) {
    { *self.value.lock().unwrap() += delta; }
    // more work without holding the lock
}

// Avoid — lock held for the rest of the function
fn add(&self, delta: i32) {
    let mut v = self.value.lock().unwrap();
    *v += delta;
    // ...
}
```

Use a `let` binding, not `while let`, when receiving from a `Mutex`-guarded channel: a `while let` keeps the guard temporary alive for the whole loop body, holding the lock across the job and starving other workers. A `let` statement drops the temporary at its `;`.

```rust
// Idiomatic — lock released before the job runs
let job = receiver.lock().unwrap().recv().unwrap();
job();

// Avoid — lock held for the entire job
while let Ok(job) = receiver.lock().unwrap().recv() {
    job();
}
```

Further deadlock-avoidance rules:

- **Never call arbitrary closures or external code while holding a lock**, and never return a `MutexGuard` to a caller. Both hand control of lock lifetime to code that may re-enter the same lock.
- **Group data that must stay consistent under one `Mutex`**, not several. Separate locks on coupled data invite lock-inversion deadlocks and TOCTOU inconsistencies.

```rust
// Idiomatic
struct GameServer { state: Mutex<GameState> }
// Avoid — two locks acquired in differing orders deadlock
struct GameServer {
    players: Mutex<HashMap<String, Player>>,
    games: Mutex<HashMap<GameId, Game>>,
}
```

**Mutex poisoning:** a `Mutex` poisons itself if a thread panics while holding the guard, signaling possibly-inconsistent data. `.lock().unwrap()` then re-panics — fine when you want failure to propagate. To recover deliberately, match the `Err` and call `poisoned.into_inner()`.

## Atomics and memory ordering

For a plain shared counter or flag, reach for `std::sync::atomic` (`AtomicUsize`, `AtomicBool`, …) before `Mutex` — no lock overhead, no deadlock risk.

```rust
let counter = Arc::new(AtomicUsize::new(0));
counter.fetch_add(1, Ordering::SeqCst);
```

Default to `Ordering::SeqCst` when unsure; it is the strongest and easiest to reason about. Relax only after proving correctness — a wrong relaxation is a data race, and weaker orderings only help on weakly-ordered hardware. When you do relax, pair `Acquire` on acquisition with `Release` on release of the same location so the happens-before relationship (all writes before the `Release` are visible after the `Acquire`) holds. `Relaxed` is appropriate for commutative metrics and an `Arc`-style refcount increment, but a lock release with `Relaxed` is wrong — another thread may never see the lock as held.

Prefer dedicated fetch methods (`fetch_add`, `fetch_sub`, …) over a `compare_exchange` loop for commutative updates: they never fail, avoid retry overhead, and map to dedicated instructions that scale better under contention.

Use `compare_exchange` rather than a separate `load` then `store` to avoid a TOCTOU window where another thread mutates the value between the two operations. Inside a retry loop, prefer `compare_exchange_weak`: on architectures lacking native CAS (e.g. ARM), the strong variant internally loops to mask spurious failures, so a strong CAS inside your own loop is a loop-in-a-loop. `_weak` delegates the spurious case to your outer loop for tighter codegen.

```rust
// Idiomatic — single atomic check-and-set, weak inside the retry loop.
// Acquire on success pairs with the Release in unlock(); the failure
// ordering can be Relaxed since a failed CAS synchronizes with nothing.
loop {
    match lock.compare_exchange_weak(false, true, Ordering::Acquire, Ordering::Relaxed) {
        Ok(_) => break,
        Err(_) => std::hint::spin_loop(),
    }
}
// ... critical section ...
lock.store(false, Ordering::Release); // publishes the section's writes

// Avoid — TOCTOU: another thread can slip in between load and store
while lock.load(Ordering::Acquire) {}
lock.store(true, Ordering::Release);
```

Start simple (coarse locks, channels, `SeqCst`) and only hand-roll lock-free structures after a benchmark proves the standard primitives are the bottleneck. Premature lock-splitting introduces correctness bugs without measurable benefit; channels and stdlib locks are already heavily optimized.

## Testing and debugging concurrent code

Don't try to flush out races by running a test ten thousand times in a loop — rare interleavings may never appear. Use **Loom**: substitute `loom::sync` / `loom::thread` in tests and Loom exhaustively replays every valid interleaving at synchronization points, guaranteeing coverage of all orderings.

Don't debug with `println!`. Each call acquires the stdout `Mutex`, adding a synchronization point that can mask the very race you are chasing (a Heisenbug). Use `tracing` or a per-thread in-memory ring buffer instead.

## Data parallelism with rayon

For data-parallel workloads, prefer rayon's parallel iterators over manual thread spawning or a hand-built threadpool with channels. Rayon handles synchronization and load-balancing for you and is guaranteed never to introduce data races (it relies on `Send`/`Sync`). Once code is in functional `map`/`collect` style, parallelizing is a one-word change: `iter()` → `par_iter()`.

```rust
use rayon::prelude::*;
let results: Vec<_> = items.into_par_iter().map(process).collect();
```

An imperative `for` loop with a `push` accumulator cannot be handed to rayon — refactor to functional style first. Size a custom pool to cores via `ThreadPoolBuilder::new().num_threads(num_cpus::get())`.

## Async/await

Async suits I/O-bound work; threads (or rayon) suit CPU-bound work. An async task costs ~0.3 µs to create and ~0.2 µs to switch versus ~17 µs and ~1.7 µs for an OS thread, so for code dominated by waiting, async wins decisively. CPU-bound code cannot yield to the event loop, so run it on threads to avoid starving other tasks.

**Never block the executor thread.** An async runtime multiplexes many tasks onto a few threads; any blocking call (a syscall, `std::thread::sleep`, a tight compute loop, even a few-millisecond `bcrypt`/regex/hash) stalls *every* task on that thread. The practical ceiling is ~10–100 µs; beyond that, offload. Blocking the event loop turns a handful of requests into a denial of service.

```rust
// Idiomatic — offload blocking/CPU work, await the result
let hash = tokio::task::spawn_blocking(move || verify_password(&pw, &h)).await?;
let now = tokio::time::sleep(dur).await; // async sleep yields the task

// Avoid — pins the executor thread, starves all other tasks
async fn handler() {
    std::thread::sleep(Duration::from_secs(1));
    let ok = verify_password(&pw, &h); // blocking CPU work inline
}
```

**Spawn independent tasks; don't await them serially.** Awaiting a sub-future inline runs work one item at a time. `tokio::spawn` makes each unit a separate task the runtime can run concurrently — and in parallel across threads if the future is `Send`.

```rust
// Idiomatic — each connection is its own task
while let Ok((stream, _)) = listener.accept().await {
    tokio::spawn(handle_client(stream));
}

// Avoid — one connection handled at a time
while let Ok((stream, _)) = listener.accept().await {
    handle_client(stream).await?;
}
```

**Always bound concurrency.** Replace worker-pool boilerplate with stream combinators: `buffer_unordered(n)` / `for_each_concurrent(n, …)` drive up to `n` futures at once and apply back-pressure, where unbounded `spawn`-per-item exhausts file descriptors, sockets, and memory.

```rust
stream::iter(jobs)
    .map(process)
    .buffer_unordered(limit)
    .collect::<Vec<_>>()
    .await
```

Choose the channel type by pattern: `oneshot` for a single result, `mpsc` for a work queue, `broadcast` for pub/sub fan-out, `watch` for latest-value state. When a bounded `mpsc` producer can block on a full channel, spawn it in its own task so it never starves the consumer that should be draining it.

Use async-aware synchronization inside futures. A `tokio::sync::Mutex` suspends the *task* rather than the thread, so holding it across an `.await` doesn't block the executor — a `std::sync::Mutex` guard held across `.await` does. Wrap a `!Send` or `&mut self` async client (e.g. a WebDriver handle) in a `tokio::sync::Mutex` to share it across tasks, locking only for the mutable borrow's duration. For simple shared scalars, an `Arc<Atomic*>` beats `Arc<Mutex<scalar>>`. Use `tokio::sync::Barrier` to wait for a fixed set of tasks to all reach a point (Go's `WaitGroup`).

**Runtime hygiene.** Use `#[tokio::main]`; know it expands to building a runtime and calling `block_on`. Pick `flavor = "multi_thread"` for servers so the work-stealing scheduler uses all cores. Libraries must **not** start a runtime internally — let the caller own it. Never mix runtimes (tokio + async-std) in one binary; their I/O drivers, timers, and schedulers are not interoperable and produce panics or silent misbehavior. Wire `tokio::signal::ctrl_c()` into graceful shutdown (e.g. `bind_with_graceful_shutdown`) so in-flight requests drain before exit.

**The `Future` contract.** When `poll` returns `Poll::Pending`, it must have arranged for the `Waker` from the `Context` to be called when progress is possible (e.g. `self.shared.waker.register(cx.waker())`). Returning `Pending` without registering a waker deadlocks the task forever. `poll` takes `Pin<&mut Self>`; do not poll a future again after it returns `Poll::Ready` (it may panic). If you need to poll past completion, wrap it with `FutureExt::fuse()` and check `is_terminated()`.

## Signal handlers

A signal handler runs asynchronously, can interrupt or block other deliveries of the same signal, and must do the absolute minimum. Set a flag and return; do all real cleanup in the main loop that polls the flag. Heavy work inside a handler risks re-entrancy, missed signals, and deadlock.

```rust
use std::sync::atomic::{AtomicBool, Ordering};
static SHUT_DOWN: AtomicBool = AtomicBool::new(false);

fn handle_signal(_: i32) {
    SHUT_DOWN.store(true, Ordering::Relaxed); // AtomicBool, not `static mut` — a plain bool write here is a data race
}
// main loop:
while !SHUT_DOWN.load(Ordering::Relaxed) { do_work(); }
```

Prevent duplicate process instances with a single-instance lock keyed on a stable machine-derived identifier, rather than trusting the OS or a scheduler (cron may launch a fresh instance every minute, racing your shared state) to enforce single execution.

## Building a thread pool

A pool bounds concurrency: spawning one thread per request invites DoS via resource exhaustion. Fix the size and feed work through a shared channel.

Bound the job type as `FnOnce() + Send + 'static` — `FnOnce` because each job runs once, `Send` to cross the thread boundary, `'static` because the worker may outlive the submitting frame.

```rust
pub fn execute<F>(&self, f: F)
where F: FnOnce() + Send + 'static { /* ... */ }
```

The receiver is single-consumer, not `Clone` and not `Sync`, so share it as `Arc<Mutex<Receiver<T>>>`: `Arc` for shared ownership, `Mutex` so exactly one worker dequeues at a time.

```rust
let receiver = Arc::new(Mutex::new(receiver));
for id in 0..size {
    workers.push(Worker::new(id, Arc::clone(&receiver)));
}
```

For graceful shutdown, **match on `recv()`** in the worker (`Ok(job) => job()`, `Err(_) => break`) instead of `unwrap`-ing, then **drop the sender before joining** so blocked `recv()` calls return `Err` and the threads can exit; otherwise `join()` deadlocks.

```rust
fn drop(&mut self) {
    drop(self.sender.take()); // close channel so recv() errors
    for worker in &mut self.workers {
        if let Some(t) = worker.thread.take() { t.join().unwrap(); }
    }
}
```

## Implementing Send and Sync (unsafe)

`Send` and `Sync` are auto-derived from a type's components; let composition do the work. Hand-implementing them is `unsafe` and an incorrect impl is undefined behavior — only do it in low-level code (e.g. a custom collection holding raw pointers), and mirror the bounds of the stdlib type you imitate.

```rust
// Idiomatic — bounded on T, mirroring Box/Arc
unsafe impl<T: Send + Sync> Send for MyArc<T> {}
unsafe impl<T: Send + Sync> Sync for MyArc<T> {}

// Avoid — unconditional impl lets MyArc<Rc<T>> cross threads → data race
unsafe impl<T> Send for MyArc<T> {}
```

In custom collections, store owned heap pointers as `NonNull<T>` rather than `*mut T`: raw pointers are neither `Send` nor `Sync` (blocking your type even when `T` is safe) and lack covariance and the null-pointer optimization. Then add the bounded `unsafe impl`s above.

When hand-writing an `Arc`-like type, use `Relaxed` for clone (increment only, no data accessed), and `Release` on the `Drop` decrement plus an `Acquire` fence on the final drop so the destroying thread sees every prior write. Guard against refcount overflow: if a count nears `isize::MAX` (reachable by leaking via `mem::forget`), `process::abort()` — silent `usize` wraparound causes premature free and use-after-free.
