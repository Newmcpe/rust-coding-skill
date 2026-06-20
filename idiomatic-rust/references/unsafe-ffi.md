# Unsafe & FFI

Writing sound `unsafe` Rust: raw pointers, invariants, undefined behavior, and crossing the C boundary safely.

## The Mental Model: `unsafe` Is a Contract, Not an Escape Hatch

`unsafe` does not turn off safety checks — it transfers responsibility for upholding Rust's invariants from the compiler to *you*. On a function it signals "callers must read the docs and uphold preconditions"; on a block it signals "I have personally verified these operations are sound." Wrapping unsound logic in `unsafe` shifts blame without providing safety.

Keep these two meanings distinct: `unsafe fn` is a contract *for the caller*; `unsafe {}` is the author's *proof* that the operations inside are sound. Conflating them either hides caller obligations or buries unreviewed assumptions. Never strip an `unsafe` marker off an internal API just to avoid typing `unsafe {}` at call sites — the noise is an intentional prompt to re-check preconditions.

Prefer to **not write unsafe at all**. `Rc`, `Arc`, `Mutex`, `Pin`, `once_cell`, `cxx` and friends already contain battle-tested, audited unsafe internals. The unsafe you need has almost certainly already been written and reviewed by someone else. Prefer safe reference types (`&T`/`&mut T`) over raw pointers everywhere — references compile to the same machine code but keep the borrow checker's guarantees.

When unsafe is genuinely unavoidable: keep blocks minimal, add `// SAFETY:` comments stating which precondition you've verified, enable `#![deny(unsafe_op_in_unsafe_fn)]`, run **Miri**, and write extra tests.

```rust
// Idiomatic: a SAFETY comment positively proves the verified precondition
unsafe {
    // SAFETY: idx < arr.len() checked above, so get_unchecked is in-bounds.
    Some(*arr.get_unchecked(idx))
}

// Avoid: a large, undocumented block where any line could be the UB
unsafe { /* many raw-pointer ops, no reasoning */ }
```

## Encapsulate Unsafe Behind a Safe API

Minimize unsafe *surface area*. A safe wrapper means callers never write `unsafe` themselves, and any memory bug is localized to the one auditable spot. Use `to_bits`/`from_bits` for float↔int reinterpretation rather than `transmute` — same result, zero unsafe.

```rust
// Idiomatic: validate inputs, hide the unsafe, expose a safe signature
pub fn split_at_mut(values: &mut [i32], mid: usize) -> (&mut [i32], &mut [i32]) {
    let len = values.len();
    let ptr = values.as_mut_ptr();
    assert!(mid <= len);
    unsafe {
        (slice::from_raw_parts_mut(ptr, mid),
         slice::from_raw_parts_mut(ptr.add(mid), len - mid))
    }
}

// Avoid: an unsafe fn forces every caller into an unsafe block
pub unsafe fn split_at_mut_all_unsafe(/* ... */) { /* ... */ }
```

## Safety Is Non-Local — Bound It by Module Privacy

An `unsafe` block's soundness depends on *all* the safe code that establishes the state it relies on. Changing `<` to `<=` in a bounds check, or mutating a field outside the unsafe block, can silently introduce UB. The only bullet-proof boundary is a **module with private fields**: make invariant-breaking helpers private so no outside code can violate the invariants your unsafe code assumes. The wider the visibility (`pub` > `pub(crate)` > private), the larger the trust boundary you must audit.

```rust
mod vec_impl {
    pub struct Vec<T> { ptr: *mut T, len: usize, cap: usize }
    fn make_room(&mut self) { self.cap += 1; } // private: only this module can break the invariant
}
```

## `unsafe` Traits

Mark a trait `unsafe` **only when a wrong safe impl can cause memory unsafety in safe calling code** (e.g. `Send`, `Sync`). Logical traits like `Eq`, `Hash`, `Ord`, `Deref` stay safe even though buggy impls cause wrong answers — so unsafe code must **never** rely on their correctness (don't assume `Hash` is stable or `Deref` returns the same pointer twice).

When implementing `Send`/`Sync` by hand, always propagate the bound to generic parameters — a bare `unsafe impl<T> Send` claims thread-safety even for `T = Rc<_>`, which is unsound.

```rust
// Good: bound propagated — only Send when the contents are
unsafe impl<T: Send> Send for MyBuf<T> {}

// Bad: lies about T — unsound for non-Send T
unsafe impl<T> Send for MyBuf<T> {}
```

## Raw Pointers

- **Only dereference pointers you derived from valid references or allocations you own.** Casting an arbitrary integer address and reading it is immediate UB.
- **Bound unbounded lifetimes at function boundaries.** Dereferencing a raw pointer yields a reference whose lifetime can silently inflate to `'static`. Constrain it in the signature so the compiler enforces it.
- **Pick the pointer type by the variance and nullability you need:** `NonNull<T>` (covariant, never-null, enables `Option<NonNull<T>>` niche optimization), `*const T` (covariant, nullable), `*mut T` (invariant in `T`). Prefer `NonNull` in self-referential / intrusive structures.
- **Use `.offset(n)` / `.add(n)` for pointer arithmetic, not integer addition** — it advances by `n * size_of::<T>()`, so element stride is automatic and stride mistakes are impossible.
- **Cast `&T` to `*mut T` in two steps:** `&x as *const T as *mut T`. Rust forbids `&T as *mut T` directly, and going through `&mut` to a `static` triggers strict alias analysis (prefer the `*const`-first path).
- Cap allocations at `isize::MAX` bytes — `ptr::offset` / LLVM GEP take a *signed* offset, so larger allocations can wrap.

```rust
// Idiomatic: pointer derived from owned data; lifetime bound in signature
unsafe fn as_ref<'a>(ptr: *const u32) -> &'a u32 { &*ptr }

// Avoid: arbitrary address — UB
let r = 0x012345usize as *const i32;
unsafe { println!("{}", *r); }
```

## Avoid `static mut`

`static mut` makes every access `unsafe`, loses type-safe error handling, and lets callers silently forget to check it (the C `errno` anti-pattern). Use `Result` to surface errors, and thread-safe interior mutability (`Mutex`, `OnceLock`, atomics) for genuinely global state. Distinguish `static` (one fixed address, always a pointer deref) from `const` (value inlined/duplicated at each use site): use `const` for small hot values and `static` for large values you don't want copied.

## Uninitialized Memory

Use `MaybeUninit`, not the deprecated `mem::uninitialized` or a useless zeroing write in hot paths. The critical rule: **never form a reference (`&`/`&mut`) to uninitialized data** — it is UB even if you never read through it.

- Use `ptr::addr_of_mut!` to get a field pointer without an intermediate reference.
- Use `ptr::write` to initialize (no drop of old garbage, no read) and `ptr::read` to move out. Assigning via `*p = x` drops the prior value and reads it as a valid `T` — both UB on uninit memory.
- Initialize array slots with `MaybeUninit::new(val)`, never `*slot.as_mut_ptr() = val` (which drops uninit memory).
- For C output-parameter structs with no Rust constructor, start from `mem::zeroed()` in one `unsafe` block, then fill the fields you need before the call.

```rust
// Idiomatic
let mut uninit = MaybeUninit::<Demo>::uninit();
let f_ptr = unsafe { std::ptr::addr_of_mut!((*uninit.as_mut_ptr()).field) };
unsafe { f_ptr.write(true); }
let init = unsafe { uninit.assume_init() };

// Avoid: reference to uninitialized field — UB
let r = unsafe { &mut (*uninit.as_mut_ptr()).field };
```

## transmute — Almost Always Wrong

- **Reach for a safe alternative first:** `f32::to_bits`/`from_bits`, `as` casts, `bytemuck`. `transmute` is the single most dangerous function in the language.
- **Never `transmute` `&T` to `&mut T`.** The optimizer assumes a shared reference is immutable for its whole lifetime; violating that lets it miscompile even with no visible mutation. Use `UnsafeCell` for interior mutability instead.
- **Only `transmute` between `repr(C)` / `repr(transparent)` types with identical layout.** `repr(Rust)` types have no guaranteed field order — even `Vec<i32>` and `Vec<u32>`, or `Foo<u8>` and `Foo<i8>`, may differ.
- **The one legitimate use is casting a data pointer to a function pointer** — and only when the target memory is executable (`.text`, or `mmap` with `PROT_EXEC`), correctly aligned, and the calling convention matches.

## Type Layout & Representation

- **`#[repr(C)]` on every struct/union/enum that crosses the FFI boundary** or that you cast through raw pointers. Default `repr(Rust)` reorders fields and inserts padding unpredictably; mismatched offsets cause silent data corruption. Use `std::os::raw` aliases (`c_int`, `c_long`, `c_char`) for C integers whose width is platform-dependent.
- **`#[repr(transparent)]` on single-field newtypes** to guarantee identical layout to the inner type — required before transmuting or casting `*const Wrapper` ↔ `*const Inner`.
- **Avoid `repr(packed)`** unless memory is critically constrained, and never borrow a packed field — a reference to a misaligned field is UB (and increasingly a hard error). Copying the field out (`let v = p.b;`) is fine.
- **Don't add `repr(u*)`/`repr(C)` to enums that need the null-pointer optimization** — it inflates size (e.g. `Option<&T>` loses its `size_of::<&T>()` guarantee).
- **Never map C bitflags to a Rust `enum`.** A Rust enum is only valid for declared variants; `Bar | Baz == 3` is not a variant and constructing it is instant UB. Use a `#[repr(transparent)]` integer newtype with associated constants and bitwise impls (or the `bitflags` crate).
- **Model C's `void*` as `*const ()`, never `*const Void`** (a pointer to an empty enum). Better still, give each logical C type its own distinct opaque handle so the type system catches pointer confusion at zero cost.

```rust
#[repr(C)]
struct Point { x: std::os::raw::c_int, y: std::os::raw::c_int }

// Distinct opaque handles: ctx_method(handle_ptr) is now a compile error
#[non_exhaustive] #[repr(transparent)] pub struct Ctx(std::ffi::c_void);
#[non_exhaustive] #[repr(transparent)] pub struct Handle(std::ffi::c_void);
```

## PhantomData & Variance

Rust forbids unused lifetime/type parameters in struct definitions. `PhantomData<&'a T>` is zero-sized but tells the compiler your type logically holds `&'a T`, fixing variance and drop-check. Choose the variant to match the variance you want:

- `PhantomData<&'a T>` / `PhantomData<T>` — covariant (like `Box`/`Vec`/`&T`).
- `PhantomData<*mut T>` / `PhantomData<UnsafeCell<T>>` — invariant (like `&mut`/`Cell`).
- `PhantomData<fn(T)>` — contravariant.
- `PhantomData<*const ()>` — withdraws `Send` *and* `Sync` (use to enforce a C library's single-thread contract when no raw-pointer field exists).

The wrong choice silently produces unsound variance.

**Drop-check + `#[may_dangle]`:** if your type owns a `T` only through a raw pointer and you relax the drop checker with `unsafe impl<#[may_dangle] T> Drop`, you **must** add `PhantomData<T>` so the drop checker still sees the ownership — otherwise it hands out references to values your `Drop` is about to free.

## Never Let a Panic Cross the FFI Boundary

Unwinding a Rust panic into C is undefined behavior. Either guarantee the function cannot panic, or wrap its body in `std::panic::catch_unwind` and convert to an error code. If cross-language unwinding is *intended*, opt in explicitly with `extern "C-unwind"`; the default `extern "C"` aborts on panic.

```rust
// Idiomatic: catch at the boundary, return a C-friendly code
#[no_mangle]
pub extern "C" fn oh_no() -> i32 {
    match std::panic::catch_unwind(|| { /* may panic */ 42 }) {
        Ok(_) => 0,
        Err(_) => 1,
    }
}
```

## Don't Auto-Trust `Send`/`Sync` for FFI Wrappers

A wrapper holding a raw pointer is correctly `!Send + !Sync` by default — keep it that way unless the C library's docs *explicitly* guarantee thread safety. Only then add `unsafe impl Send`/`Sync`, and gate it on what the docs promise.

## Calling C from Rust

- Declare foreign functions in `extern "C"` blocks and call them inside `unsafe`; use `#[link_name = "..."]` to bind a specific symbol and `_` for unused parameter names. Prefer **sized integer types** (`u32`) over platform-dependent ones (`c_int`) so widths match on both sides; pass struct sizes via `mem::size_of::<T>()`, never a magic number.
- **Generate bindings with `bindgen`** rather than hand-writing them — a handwritten signature that drifts from the C header is silent UB. Structure FFI as a two-crate stack: `xyzzy-sys` (raw bindgen output, all the unsafe `extern` declarations) and `xyzzy` (safe wrapper). Use `cbindgen` for the reverse direction.
- **Scope platform imports (`libc`, `winapi`) inside the function that needs them**, and gate platform-specific unsafe at compile time with `#[cfg(...)]` rather than runtime checks — it prevents link errors on unsupported targets at zero cost.
- **Mark trivial safe↔unsafe bridge wrappers `#[inline]`** so the abstraction is truly zero-cost on hot/FFI paths.
- **Strings:** use `CString` (owned) / `CStr` (borrowed) — C strings are null-terminated; `String::as_ptr()` has no terminator. Build `argv`-style arrays with `CString::into_raw`, which yields a stable heap pointer.
- **Nullable callbacks/pointers:** use `Option<extern "C" fn(...)>` / `Option<*mut T>` — the niche optimization maps `None` to null, so you check it with `match` instead of transmuting.
- **Null returns from C:** convert with `p.as_ref()` to get `Option<&T>` and handle `None` explicitly; never `&*p` an unchecked pointer.

```rust
extern "C" {
    #[link_name = "snappy_validate"]
    fn snappy_validate(src: *const u8, len: size_t) -> i32;
    fn get_callback() -> Option<extern "C" fn(i32)>; // None == null, no manual check
}

pub fn validate(src: &[u8]) -> bool {
    unsafe { snappy_validate(src.as_ptr(), src.len() as size_t) == 0 }
}
```

## Exposing Rust to C

Export with `#[no_mangle]` + `pub extern "C"` together — `pub` for visibility, `extern "C"` for the calling convention, `#[no_mangle]` so the symbol keeps its source name. Omitting any one breaks linking. Because C symbols share one global namespace, prefix names (e.g. `mylib_`) to avoid collisions.

```rust
#[no_mangle]
pub extern "C" fn mylib_process(v: u32) -> u32 { v * 2 }
```

## Ownership & Allocation Across the FFI Boundary

- **Free with the same allocator that allocated.** Rust-allocs-then-C-frees (or vice versa) mixes allocators — heap corruption. Provide symmetric `_new`/`_free` pairs.
- **Hand heap memory to C with `Box::into_raw`** (transfers ownership; returning `&mut *b` leaves the pointer dangling the instant the `Box` drops) and **reclaim it with `Box::from_raw`** in your free function, letting `Box`'s drop deallocate.
- **Prefer caller-allocated buffers for large or frequently-allocated data** (`fn fill(buf: *mut u8, len: usize)`) — it lets the caller use stack memory, pools, or custom allocators and avoids a round-trip. Reserve implementation-managed allocation for opaque/dynamically-sized results.
- **Implement `Drop` on wrapper types** so C-allocated resources are freed even on early-return / error paths — the RAII equivalent of a C destructor.

```rust
#[no_mangle]
pub extern "C" fn object_new() -> *mut FfiStruct {
    Box::into_raw(Box::new(FfiStruct::default())) // ownership → C
}

#[no_mangle]
pub unsafe extern "C" fn object_free(p: *mut FfiStruct) {
    if !p.is_null() { drop(Box::from_raw(p)); } // Box drop frees it via the Rust allocator
}
```

## Exception Safety in Unsafe Algorithms

Code that temporarily breaks invariants (e.g. raising a `Vec`'s `len` before its slots are written) must ensure a panic in that window can't expose the broken state. Rust has no `finally`: encode cleanup in a **guard struct's `Drop`** (the `Hole` / `RawVec` pattern), or order operations so the invariant-restoring step (`set_len`) runs **only after** every fallible operation succeeds — never bump `len` before the slots are filled, or a panic in `T::default()`/`clone()` runs destructors on uninitialized memory.

```rust
// Idiomatic: write all slots first, raise len last
unsafe {
    for i in 0..fill { self.ptr().add(start + i).write(T::default()); }
    self.set_len(start + fill); // only reached if no write panicked
}
```

## Building Collections: ZSTs and Sentinels

When implementing raw containers, zero-sized types are the perennial footgun:

- Use `NonNull::dangling()` as the sentinel for "nothing allocated" and ZST allocations — it's non-null (satisfying `NonNull`'s invariant and the allocator contract) and well-aligned. Never use `null_mut()`.
- For ZSTs, set `cap = usize::MAX` upfront and `assert!(size_of::<T>() != 0)` in `grow()` — ZSTs never OOM, so capacity would otherwise wrap.
- In `size_hint`, divide by `if elem_size == 0 { 1 } else { elem_size }` to avoid divide-by-zero.
- Skip `dealloc` when `cap == 0 || elem_size == 0` — calling the allocator with a zero-sized layout or dangling pointer is UB.
- Use `ManuallyDrop` to destructure a `Drop` type (e.g. building `IntoIter` from a `Vec`) without freeing the buffer it still points to.

## `no_std`, Kernels & Freestanding Binaries

- A `#![no_std]` binary or cdylib needs **exactly one** `#[panic_handler]` in its whole dependency graph — zero leaves `panic!` unresolved, multiple is a link error.
- Unwinding needs runtime support `no_std` lacks: set `panic = "abort"` in **both** `[profile.dev]` and `[profile.release]` (with `opt-level = "z"`, `lto = true`, `codegen-units = 1` for minimal size), not just release.
- Make freestanding entry points `#[no_mangle] pub extern "C" fn _start() -> !` — `no_mangle` so the linker finds it, `extern "C"` for the bootloader ABI, `-> !` because it never returns. A diverging entry/syscall path with `loop {}` also lets the compiler drop the stack-cleanup epilogue.
- A kernel `#[panic_handler]` should `intrinsics::abort()` (halt), not `loop {}` (which pegs a core at 100%).
- For memory-mapped I/O, use `ptr::write_volatile` so the optimizer can't elide hardware-visible stores.
- Size ABI buffers from `mem::size_of::<usize>() * N` rather than hardcoding byte widths, so layout is correct on both 32- and 64-bit targets. Mirror C ABI structs with `#[repr(C)]`.
- Re-register self-resetting (SysV) signal handlers at the *start* of each invocation to close the race where a second signal hits the default handler. Suppress/restore signals with `libc::signal(SIG, SIG_IGN/SIG_DFL)` inside `unsafe`.
- In position-independent / injected code, store data as **stack locals**, never `const` statics — statics bake in absolute addresses that break after relocation; stack data is RIP-relative. To embed bytes into a named section, compute the length as a `const` and store a fixed-size array (`static D: [u8; LEN] = *include_bytes!(...)`) under `#[link_section]`.
