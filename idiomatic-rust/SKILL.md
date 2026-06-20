---
name: idiomatic-rust
description: Use whenever writing, reviewing, refactoring, or generating Rust — any .rs file, Cargo project, or request like "write a Rust function/CLI/library", "fix this Rust", "make this idiomatic", "satisfy the borrow checker", or "clean up clippy warnings". This skill makes code-writing agents produce clean, correct, idiomatic Rust: it enforces type-system-first data modeling so invalid states are unrepresentable, Result/? error handling instead of panics, iterator chains over index loops, ownership and borrowing that the borrow checker accepts without needless clones or unwraps, and a mandatory cargo fmt + cargo clippy -D warnings + cargo test gate before any work is called done. Covers application, library, systems, and network/security tooling code alike. Apply it proactively on every Rust task, not only when asked.
---

# Idiomatic Rust

## When to use

Use for any task that produces or changes Rust: new code, refactors, reviews, bug fixes, or generating snippets. If a `.rs` file, `Cargo.toml`, or Rust idiom is in scope, this skill governs how you work. Default to it; do not wait to be asked.

## Core operating procedure

Follow this loop in order every time you write Rust. Each step prevents a class of defect the next step cannot fix.

1. **Model the data with the type system first.** Before writing logic, design the types. Use enums for "one of" and structs for "all of". Make invalid states unrepresentable — if a value can never legally be two things at once, do not store two fields; use an enum. Wrap primitives in newtypes (`struct UserId(u64)`) when they carry meaning, so the compiler rejects mixing them. Derive `Debug`, and `Clone`/`PartialEq`/`Eq`/`Hash`/`Default` where they make sense. See `references/data-modeling.md`.
2. **Choose ownership deliberately.** Decide what owns each value and what merely borrows it. Take `&str`/`&[T]` parameters rather than `&String`/`&Vec<T>`; return owned values rather than dangling references; accept `impl Into<String>` or generic borrows where it improves the API. Reach for `clone()` only when a borrow genuinely cannot satisfy the lifetimes — never to silence the borrow checker. See `references/ownership-borrowing.md`.
3. **Handle errors with `Result` and `?`, not panics.** Library code returns `Result<T, E>` / `Option<T>`; it does not `unwrap`, `expect`, or `panic!` on conditions a caller could hit. Define a custom error type (`thiserror` for libraries, `anyhow` for applications) and let `?` propagate with `From` conversions. Reserve panics for true bugs (broken invariants), and prefer `expect("invariant: ...")` over `unwrap()` when you must. See `references/error-handling.md`.
4. **Prefer iterators and combinators over manual loops and indexing.** Express transformations as lazy adapter chains (`iter().filter().map().collect()`); use `collect::<Result<_, _>>()` to short-circuit fallible work; use the `entry` API for map updates. Index into slices only when the algorithm truly needs positions. See `references/collections-iterators.md`.
5. **Use traits, generics, and lifetimes idiomatically.** Bound generics with the traits they need; prefer static dispatch, reaching for `dyn` only for heterogeneous collections or to shrink code size; implement `From`/`TryFrom` for conversions; lean on elision and add explicit lifetimes only when required. See `references/traits-generics-lifetimes.md`.
6. **Run `cargo fmt`, then `cargo clippy -- -D warnings`, and fix every finding.** Do not suppress lints with `#[allow(...)]` unless you can justify it in a comment. Clippy's suggestions are idiom guidance — apply them, do not silence them.
7. **Write tests.** Add `#[cfg(test)]` unit tests for logic and edge cases, integration tests for public behavior, and doc tests for examples. Cover the error paths, not just the happy path. See `references/testing.md`.

## Non-negotiables

- No needless `clone()` — clone only when ownership is genuinely required, never to dodge the borrow checker.
- No `unwrap()` / `expect()` / `panic!` in library code on caller-reachable conditions; propagate with `?`. Panics are for bugs only.
- Never swallow errors (`let _ = result;`, empty `match` arms, `.ok()` to discard). Propagate or handle them meaningfully.
- No `unsafe` without a `// SAFETY:` comment documenting the invariant that makes it sound, and the encapsulation that upholds it.
- Make invalid states unrepresentable; do not validate at runtime what the type system can forbid at compile time.
- Code must pass `cargo clippy -- -D warnings` with zero `#[allow]` escape hatches that lack a written justification.
- Prefer borrowing over owning in signatures (`&str`, `&[T]`, `impl AsRef<_>`); return owned data, never references to locals.
- Follow standard naming: `snake_case` items, `CamelCase` types, `SCREAMING_SNAKE_CASE` consts, `new`/`with_*`/`try_*` constructors.

## Reference map

Open the relevant file on demand — read it when the task touches its area, not upfront.

| Task / trigger | Reference |
| --- | --- |
| Moves, borrows, lifetimes, clone avoidance, slices, thread closures | `references/ownership-borrowing.md` |
| `Result`/`Option`, `?`, custom errors, `thiserror`/`anyhow`, panics, CLI exit codes | `references/error-handling.md` |
| Enums/structs, newtypes, typestate, making invalid states unrepresentable, builders, derives, `Default` | `references/data-modeling.md` |
| Generics, trait bounds, associated types, static vs `dyn` dispatch, `impl Trait`, conversions | `references/traits-generics-lifetimes.md` |
| Iteration, `collect`, `entry` API, `Vec` capacity, UTF-8-safe `String` handling | `references/collections-iterators.md` |
| Cargo, dependency versions, modules, visibility, re-exports, semver, features, workspaces, CI | `references/project-structure.md` |
| `Box`/`Rc`/`Arc`/`Weak`, `RefCell`/`Cell`, `Deref`, `Drop`/RAII | `references/smart-pointers.md` |
| Threads, channels, `Arc<Mutex<_>>`, atomics/ordering, thread pools, `Send`/`Sync` | `references/concurrency.md` |
| Test placement, assertions, panic/`Result` tests, integration/doc tests, TDD, fuzzing | `references/testing.md` |
| Naming/casing, constructors, receiver choice, borrowed args, type aliases, operator overloading | `references/api-design-naming.md` |
| `unsafe` contracts, raw pointers, `transmute`, `repr`, FFI, calling/exposing C, `no_std` | `references/unsafe-ffi.md` |
| Bindings/mutability, expression style, control flow, closures, imports, conversions, macros, ranges | `references/idioms-antipatterns.md` |
| Network/security tooling: async scanners, bounded concurrency, timeouts/rate limits, untrusted-input parsing, secrets handling, TLS, static binaries, CLIs | `references/security-tooling.md` |

## Verification

You are not done until all three pass cleanly. Run them and fix every finding before claiming completion — do not report success on unverified code.

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

Or run the bundled gate: `scripts/check.sh` (POSIX) / `scripts/check.ps1` (Windows) — it runs all three and stops on the first failure.

If formatting differs, run `cargo fmt` and re-check. If clippy reports lints, fix the code (do not blanket-`allow`). If tests fail, fix the implementation or the test, then re-run the full gate. Iterate until all three are green.
