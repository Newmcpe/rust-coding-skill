# Idiomatic Rust

When writing, refactoring, or reviewing Rust, follow this ruleset. The full version is in `AGENTS.md`; per-topic detail is in `rust-coding-skill/references/` — consult the relevant file.

## Procedure
1. **Types first** — enums for "one of", structs for "all of", newtypes for meaningful primitives; make invalid states unrepresentable. (`data-modeling.md`)
2. **Borrow deliberately** — `&str`/`&[T]`, not `&String`/`&Vec<T>`; never `clone()` to dodge the borrow checker. (`ownership-borrowing.md`)
3. **Errors via `Result`/`?`** — no `unwrap`/`expect`/`panic!` in libraries; `thiserror` for libs, `anyhow` + `.context` for apps. (`error-handling.md`)
4. **Iterators over manual loops** — adapter chains, `collect::<Result<_,_>>()`, the `entry` API. (`collections-iterators.md`)
5. **Idiomatic traits/generics** — static dispatch by default, `dyn` only when needed; `From`/`TryFrom`. (`traits-generics-lifetimes.md`)
6. **`cargo fmt`, then `cargo clippy -- -D warnings`** — fix every lint; no unjustified `#[allow]`.
7. **Tests** — cover error paths, not just the happy path. (`testing.md`)

## Non-negotiables
- No needless `clone()`; no `unwrap`/`expect`/`panic!` in libraries on caller-reachable conditions.
- Never swallow errors (`let _ = result;`, `.ok()`-and-ignore); propagate with `?` or handle.
- No `unsafe` without a `// SAFETY:` comment documenting the invariant that makes it sound.
- Make invalid states unrepresentable; prefer borrowing in signatures, return owned data.
- Standard naming: `snake_case` items, `CamelCase` types, `SCREAMING_SNAKE_CASE` consts, `new`/`with_*`/`try_*` constructors.

## Verification
Not done until clean: `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, `cargo test`.
