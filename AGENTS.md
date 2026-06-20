# Idiomatic Rust — agent ruleset

Cross-agent instructions ([AGENTS.md](https://agents.md) standard) for any coding agent producing or changing Rust. Claude Code reads `rust-coding-skill/SKILL.md`; this file is the portable equivalent for Codex, Cursor, Zed, Aider, Jules, and anything else that honours `AGENTS.md`. The detailed rules live in `rust-coding-skill/references/` — open the one a task needs rather than loading everything.

## Core operating procedure

Follow this loop in order every time you write Rust. Each step prevents a class of defect the next step cannot fix.

1. **Model the data with the type system first.** Design types before logic. Enums for "one of", structs for "all of". Make invalid states unrepresentable; wrap meaningful primitives in newtypes (`struct UserId(u64)`). Derive `Debug` and `Clone`/`PartialEq`/`Eq`/`Hash`/`Default` where sensible. → `rust-coding-skill/references/data-modeling.md`
2. **Choose ownership deliberately.** Decide what owns and what borrows. Take `&str`/`&[T]` over `&String`/`&Vec<T>`; return owned values, never references to locals. Reach for `clone()` only when a borrow genuinely cannot satisfy the lifetimes — never to silence the borrow checker. → `rust-coding-skill/references/ownership-borrowing.md`
3. **Handle errors with `Result` and `?`, not panics.** Libraries return `Result`/`Option` and do not `unwrap`/`expect`/`panic!` on caller-reachable conditions. Use `thiserror` for libraries, `anyhow` (with `.context`) for applications; let `?` propagate via `From`. Panics are for true bugs only. → `rust-coding-skill/references/error-handling.md`
4. **Prefer iterators and combinators over manual loops.** Lazy adapter chains (`iter().filter().map().collect()`); `collect::<Result<_,_>>()` to short-circuit; the `entry` API for maps. Index only when positions truly matter. → `rust-coding-skill/references/collections-iterators.md`
5. **Use traits, generics, and lifetimes idiomatically.** Bound generics with the traits they need; prefer static dispatch, `dyn` only for heterogeneous collections or code size; implement `From`/`TryFrom`; lean on lifetime elision. → `rust-coding-skill/references/traits-generics-lifetimes.md`
6. **Run `cargo fmt`, then `cargo clippy -- -D warnings`, and fix every finding.** Do not suppress lints with `#[allow(...)]` without a written justification. Clippy is idiom guidance — apply it.
7. **Write tests.** `#[cfg(test)]` units for logic and edge cases, integration tests for public behaviour, doc tests for examples. Cover error paths, not just the happy path. → `rust-coding-skill/references/testing.md`

## Non-negotiables

- No needless `clone()` — clone only when ownership is genuinely required.
- No `unwrap()`/`expect()`/`panic!` in library code on caller-reachable conditions; propagate with `?`.
- Never swallow errors (`let _ = result;`, `.ok()`-and-ignore, empty match arms). Propagate or handle them.
- No `unsafe` without a `// SAFETY:` comment documenting the invariant that makes it sound.
- Make invalid states unrepresentable; don't validate at runtime what the type system can forbid at compile time.
- Code must pass `cargo clippy -- -D warnings` with no unjustified `#[allow]`.
- Prefer borrowing in signatures (`&str`, `&[T]`, `impl AsRef<_>`); return owned data.
- Standard naming: `snake_case` items, `CamelCase` types, `SCREAMING_SNAKE_CASE` consts, `new`/`with_*`/`try_*` constructors.

## Reference map

Open the file on demand when the task touches its area.

| Task | Reference |
|---|---|
| Moves, borrows, lifetimes, clone avoidance, slices | `rust-coding-skill/references/ownership-borrowing.md` |
| `Result`/`Option`, `?`, custom errors, `thiserror`/`anyhow`, panics | `rust-coding-skill/references/error-handling.md` |
| Enums/structs, newtypes, typestate, invalid-states-unrepresentable, const generics | `rust-coding-skill/references/data-modeling.md` |
| Generics, trait bounds, associated types, static vs `dyn`, AFIT, conversions | `rust-coding-skill/references/traits-generics-lifetimes.md` |
| Iteration, `collect`, `entry` API, UTF-8-safe `String` | `rust-coding-skill/references/collections-iterators.md` |
| Cargo, modules, editions, visibility, semver, features, workspaces, CI | `rust-coding-skill/references/project-structure.md` |
| `Box`/`Rc`/`Arc`/`Weak`, `RefCell`/`Cell`, `Deref`, `Drop`/RAII | `rust-coding-skill/references/smart-pointers.md` |
| Threads, channels, `Arc<Mutex<_>>`, atomics/ordering, async | `rust-coding-skill/references/concurrency.md` |
| Test placement, assertions, integration/doc tests, fuzzing | `rust-coding-skill/references/testing.md` |
| Naming, constructors, receiver choice, borrowed args, public-API ergonomics | `rust-coding-skill/references/api-design-naming.md` |
| `unsafe` contracts, raw pointers, `transmute`, `repr`, FFI, `no_std` | `rust-coding-skill/references/unsafe-ffi.md` |
| Bindings, expression style, closures, conversions, macros, float comparison | `rust-coding-skill/references/idioms-antipatterns.md` |
| Network/security tooling: async scanners, bounded concurrency, untrusted-input parsing, secrets, static binaries | `rust-coding-skill/references/security-tooling.md` |

## Verification

Not done until all three pass cleanly. Run them and fix every finding before claiming completion.

```sh
cargo fmt --check
cargo clippy --all-targets -- -D warnings
cargo test
```

Bundled gate: `rust-coding-skill/scripts/check.sh` (POSIX) / `rust-coding-skill/scripts/check.ps1` (Windows).
