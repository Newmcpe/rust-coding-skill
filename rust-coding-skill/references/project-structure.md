# Project Structure

Organize Rust code into modules, crates, and workspaces with a deliberately small, well-versioned public API.

## Cargo as the build authority

Use Cargo for every real project. It pins dependencies (`Cargo.lock`), drives workspaces, and gives cross-platform reproducibility; bare `rustc` is only for throwaway single files.

- `cargo check` during the edit loop — it skips codegen and is much faster than a full build (often ~20x: 0.12s vs 2.24s on the same change). Reserve `cargo build`/`--release` for shipping or benchmarking (benchmarks are meaningless on a dev build).
- **Commit `Cargo.lock` for binaries, gitignore it for libraries.** Binaries need byte-for-byte reproducible builds. Downstream consumers ignore a library's lockfile and resolve their own, so committing it only creates a false sense of control.
- `cargo doc --open` builds and browses docs for your crate *and every transitive dependency* offline — the best way to read an indirect dep's real API. Use `--no-deps` while iterating to skip rebuilding dependency docs.
- Treat `cargo` as extensible: prefer custom subcommands (`cargo bootimage`, `cargo-binutils`) over bespoke shell scripts wrapping raw `rustc`/`objcopy`, which drift from your actual dependency versions.

## Editions

The **edition** (`edition = "2024"` in `Cargo.toml`'s `[package]`) opts a crate into a coherent set of language changes — new keywords, idiom shifts, default-lint changes. It is **per-crate**, so a 2024 crate and a 2015 dependency interoperate freely; pick the newest your MSRV allows (2024, else 2021) for every new crate, and never omit it (a missing edition silently means the ancient 2015 edition).

- Editions never split the ecosystem and never force you to upgrade — old code keeps compiling on new compilers.
- Migrate with `cargo fix --edition` then bump the field; the tool rewrites the now-changed idioms (e.g. 2018's uniform paths, 2021's disjoint closure captures) for you.
- Enable `#![warn(rust_2018_idioms)]` (and successors) to catch pre-edition patterns the migration didn't.

## Dependency versioning

Specify SemVer-compatible ranges — not exact pins, not wildcards. `"1.4"` means `^1.4` (compatible updates, no major breaks), so you get security and bug fixes automatically while staying API-stable. `"=1.2.3"` blocks fixes and fragments the dep graph; `"*"` lets a major break in.

```toml
# Idiomatic
rand = "0.8"      # or "0.8.5" as a minimum

# Avoid
rand = "=0.8.5"   # too tight: blocks patches, duplicates crates
rand = "*"         # too loose: allows breaking major versions
```

**Declare the true *minimum* version that has the APIs you call, not the latest.** Pinning the lower bound to today's release (`hugs = "1.7.3"`) makes resolution fail when another dependent needs an older patch. The minimum is the oldest version exposing every API you actually use; verify with `cargo +nightly -Z minimal-versions check`.

```toml
hugs = "1.5"      # oldest version that has the API we use
# Avoid: hugs = "1.7.3"  # latest at time of writing, needlessly restricts resolution
```

Audit the graph with tooling the compiler cannot: `cargo tree --duplicates`, `cargo udeps` (unused deps), `cargo deny check` / `cargo audit` (vulnerabilities, license violations), `cargo outdated`. Run them in CI.

**Vendor dependencies (`cargo vendor`) for offline, auditable, supply-chain-transparent builds.** Vendored sources show up in `git diff`, so dependency updates get reviewed like any other code change, and builds no longer depend on crates.io being reachable (or leak builder IPs to it).

```toml
# .cargo/config.toml
[source.crates-io]
replace-with = "vendored-sources"
[source.vendored-sources]
directory = "vendor"
```

## Modules and files

- Mark items `pub` individually — a `pub mod` does **not** make its contents public. This keeps least-privilege the default.
- Prefer `src/foo.rs` over the older `src/foo/mod.rs`; many identically-named `mod.rs` tabs are confusing to navigate.
- Reference items by absolute `crate::`-rooted paths. Definitions and call sites move independently; an absolute path survives the caller relocating, a relative one breaks.
- **Declare `macro_rules!` macros before the modules that use them.** Unlike every other item, macros obey *textual* scoping — they are visible only after their definition in source order. A `mod consumers;` placed above `mod macros;` fails to compile. (Or hoist with `#[macro_export]`, below.)

```rust
// Idiomatic
pub mod hosting {
    pub fn add_to_waitlist() {}   // explicitly public
}
crate::front_of_house::hosting::add_to_waitlist();

// Avoid
pub mod hosting {
    fn add_to_waitlist() {}       // still private despite pub mod
}
front_of_house::hosting::add_to_waitlist(); // breaks if caller moves
```

## `use` conventions

Bring the **parent module** into scope for functions (`hosting::add_to_waitlist` keeps the origin visible) but the **full path** for types (`HashMap` is unambiguous on its own). Consolidate same-prefix imports with nested paths; alias with `as` when two names collide.

```rust
use crate::front_of_house::hosting;     // function: keep parent
use std::collections::HashMap;          // type: full path
use std::{cmp::Ordering, io::{self, Write}};
use std::io::Result as IoResult;        // disambiguate clash
```

Avoid wildcard (`use foo::*`) imports from crates you do not control. A minor-version upgrade can add a trait whose methods clash with yours, turning a non-breaking dependency bump into a compile error.

**Offer a `prelude` module when many traits must be in scope to use your types** (as rayon does for its iterator traits). Bundling them behind `pub mod prelude { pub use ... }` collapses a dozen import lines on the consumer side to one `use my_crate::prelude::*;`.

## Visibility and encapsulation

Default to private; widen only when required. Narrowing a public item later is a breaking (major) bump, while publishing a private one is backward-compatible — so every `pub` constrains future refactoring.

**Reach for the narrowest modifier that works**, not a binary pub/private choice: `pub(crate)` (whole crate, never downstream), `pub(super)` (parent module), `pub(in path)` (a named ancestor), `pub(self)` (effectively private). A bare `pub` on an internal helper silently enlarges your public API surface that you must then maintain across versions.

```rust
pub(crate) fn internal_helper() {}   // shared internally, invisible downstream
pub fn public_api() {}
```

Keep struct fields private and expose controlled methods. Fields default to private even on a `pub struct` (unlike enum variants), and private fields let methods enforce invariants that external mutation could violate. Expose a field with `pub` only when it is a deliberate, stable part of the API.

```rust
// Idiomatic
pub struct AveragedCollection {
    list: Vec<i32>,
    average: f64,
}
impl AveragedCollection {
    pub fn add(&mut self, v: i32) { self.list.push(v); self.update_average(); }
    pub fn average(&self) -> f64 { self.average }
    fn update_average(&mut self) { /* keeps `average` in sync */ }
}

// Avoid
pub struct AveragedCollection {
    pub list: Vec<i32>,   // callers can push without updating average
    pub average: f64,
}
```

A `pub struct` with any private field cannot be built via literal syntax — provide a public constructor (`Type::new(...)`).

## Public API as a stability contract

Your public API is more than the items you wrote `pub` on — it includes auto-trait impls and the concrete types you hand back.

- **Annotate public types you expect to grow with `#[non_exhaustive]`.** Adding a field to a plain public struct (or a variant to a plain enum) breaks downstream literal construction and exhaustive matching; `#[non_exhaustive]` opts users into forward-compatible `..` patterns from day one. The trade-off is losing exhaustive-match guarantees for callers.

```rust
#[non_exhaustive]
pub struct Config { pub timeout: Duration }
// vs. pub struct Config { ... }  — adding any field later is a breaking change
```

- **Auto traits (`Send`, `Sync`, `Unpin`) are part of your API.** Changing a private field's type can silently strip `Send`/`Sync` from a public type and break downstream code. Lock them with a zero-cost compile-only test.

```rust
fn assert_send_sync<T: Send + Sync + Unpin>() {}
#[test]
fn public_types_are_normal() { assert_send_sync::<MyType>(); }
```

- **Decouple your API from a dependency's version: return `impl Trait` or a newtype, not the dep's concrete type.** If you return `dep::Foo` directly, upgrading to `dep` 2.0 changes that type's identity and breaks your callers even if `Foo` is structurally unchanged.

```rust
pub fn iter<T>() -> impl Iterator<Item = T> { itercrate::empty() }
// vs. -> itercrate::Empty<T>  — leaks the dependency's version into your API
```

## Re-exports for a clean public API

Internal module hierarchy should reflect code organization, not dictate the paths users type. Use `pub use` to flatten deeply nested items to the crate root.

```rust
// lib.rs — internal tree stays organized, public API stays flat
pub use self::kinds::PrimaryColor;
pub use self::utils::mix;

// user code: use art::PrimaryColor;  // not art::kinds::PrimaryColor
```

**Re-export any dependency whose types appear unavoidably in your public API** (`pub use rand;`). Otherwise a caller on a semver-incompatible version of that same crate hits an opaque trait-bound mismatch; re-exporting lets them reach the exact version through `your_crate::rand::`. (Prefer the `impl Trait`/newtype escape above when you can avoid exposing the type at all.)

## Semantic versioning

Cargo's resolver trusts your version numbers, so wrong bumps break downstream in hard-to-diagnose ways.

- **MAJOR** — any removal or incompatible change. Rust-specific traps that *also* require a major bump: adding a field to a non-`#[non_exhaustive]` public struct, adding a variant to a non-`#[non_exhaustive]` enum, adding a blanket trait impl, removing a default feature, accidentally dropping an auto-trait impl.
- **MINOR** — additive, backward-compatible changes.
- **PATCH** — bug fixes only.

Published versions are immutable. Never overwrite one — `cargo yank --vers 1.0.1` retires a broken release (blocks new dependents, leaves existing `Cargo.lock` pins working) without deleting it.

## Feature flags

**Features must be additive.** Cargo unifies features across the whole graph, so the final build gets the union of everything any dependency requested. Mutually exclusive features can therefore both end up active and fail to compile — making the crate impossible to compose.

```toml
[features]
json = ["serde_json"]
xml  = ["quick-xml"]   # both can be enabled simultaneously
# Avoid two backends that are mutually exclusive: any two dependents
# enabling different sides break the build.
```

- Gate `std` with an additive `std` (or `alloc`) feature, never a negative `no_std` feature — two consumers can each enable a feature, but neither can disable one the other needs.
- Never feature-gate public struct fields or trait methods; downstream code cannot know whether a transitive dep activated the feature, making a struct literal valid only under an unknowable condition. Use `Option<T>` instead.

```rust
#![cfg_attr(not(feature = "std"), no_std)]   // [features] std = []
```

## Library / binary split

Put the bulk of the logic in `src/lib.rs` and keep the binary a thin client. Integration tests cannot import a binary crate's `main.rs`, so logic stranded there is untestable; routing it through a library also forces you to design a real public API and makes the same code embeddable in a larger toolkit.

```rust
// src/lib.rs
pub fn run(config: Config) -> Result<(), Box<dyn Error>> { /* ... */ }

// src/main.rs — only parse config, call run, handle the error
fn main() {
    let config = Config::build(&args).unwrap_or_else(|e| { eprintln!("{e}"); process::exit(1); });
    if let Err(e) = minigrep::run(config) { eprintln!("{e}"); process::exit(1); }
}
```

A crate may have only one `[lib]` but **arbitrarily many `[[bin]]` entries** (double-bracket = TOML array) sharing that library — far better than a giant `match` on argv or copying logic into each binary.

```toml
[lib]
name = "libactionkv"
path = "src/lib.rs"

[[bin]]
name = "akv_mem"
path = "src/akv_mem.rs"

[[bin]]
name = "akv_disk"
path = "src/akv_disk.rs"
```

## Documentation

Document every public item with `///`, describing **behavior and semantics**, not the signature (parameter restatements drift out of sync). Use `//!` at a file's top to document the enclosing crate/module. Plain `//` comments are invisible to rustdoc.

`# Examples` code blocks run as tests under `cargo test`, keeping docs honest. Always document `# Panics`, `# Errors`, and (for `unsafe` fns) `# Safety` — callers rely on these to uphold preconditions.

```rust
//! Simulating files one step at a time.

/// Adds one to the number given.
///
/// # Examples
/// ```
/// assert_eq!(6, my_crate::add_one(5));
/// ```
/// # Panics
/// Panics if the result overflows `i32`.
pub fn add_one(x: i32) -> i32 { x + 1 }
```

Enable `#![deny(rustdoc::broken_intra_doc_links)]` and check rendered output with `cargo doc --open`; broken doc links are otherwise silent.

## Workspaces

Use a workspace for multiple crates that evolve together — they share one `Cargo.lock` and target dir, guaranteeing version-consistent members and enabling incremental, per-crate recompilation. Splitting a monolith into focused crates is itself a build-speed win: incremental compilation operates at the crate boundary, so a single giant crate recompiles wholesale on any change. Membership grants no implicit dependencies: each crate must still list everything it uses in its own `Cargo.toml`.

```toml
# top-level Cargo.toml
[workspace]
members = ["adder", "add_one", "common"]
default-members = ["adder"]   # `cargo build` builds only this; others on demand

# adder/Cargo.toml — declare everything explicitly
[dependencies]
add_one = { path = "../add_one" }
```

- **Set `default-members`** so a bare `cargo build` targets only the deliverables, not test/tooling crates.
- **Extract shared types (API models, route constants) into a `common` crate** imported by every side. Duplicated model definitions across frontend/backend drift silently; a shared crate makes a mismatch a compile error.
- **`[profile.*]` sections only take effect in the workspace *root*** manifest. Cargo silently ignores them in member crates — a confusing footgun.

## Layered application architecture

For larger apps, structure code into layers (Presentation → Services → Entities → Repository → Drivers) where each layer talks only to its neighbours and business rules live solely in Services. Change then stays localized, and Services become testable independent of HTTP, DB, or external APIs.

**Put the database pool on the Service, not the Repository.** A multi-step atomic write needs one transaction spanning several repo calls; if the pool is trapped inside the Repository there is no clean way to thread a single transaction across them.

```rust
pub struct Service { repo: Repository, db: Pool<Postgres> }
impl Service {
    pub async fn op(&self) -> Result<(), Error> {
        let mut tx = self.db.begin().await?;
        self.repo.step_a(&mut tx).await?;
        self.repo.step_b(&mut tx).await?;
        tx.commit().await
    }
}
```

For async apps prefer **sqlx** over diesel: diesel's synchronous API blocks the executor in an async context, while sqlx is async, maps results type-safely, and checks queries against the live schema at compile time.

## Macros and crate types

- Annotate a `macro_rules!` macro meant for external use with `#[macro_export]` (also hoists it to the crate root); without it the macro stays crate-private.
- Procedural macros need a dedicated crate with `proc-macro = true`. Follow the `foo` / `foo_derive` companion-crate convention so users can depend on `foo` without pulling in the derive machinery.
- **For C/native bindings, split raw FFI into a `<lib>-sys` crate and the safe wrapper into a separate crate that depends on it.** The `links` key forbids two crates linking the same native library in one build; without the split, any bindgen regeneration forces a simultaneous major bump of bindings *and* wrapper, dragging the whole ecosystem along.

## Conditional compilation and cross-platform

Use `#[cfg(...)]` to keep platform-specific bytes out of the binary entirely — never branch on a runtime `std::env::consts::OS` string comparison, which compiles every platform's strings in. The cfg predicate language has `not(...)`, `all(...)`, `any(...)` but **no `!=`** (so `#[cfg(target_os != "x")]` is a compile error — use `not(...)`).

**Dispatch platform code in one `mod.rs` and expose a single unified symbol**, so call sites are platform-agnostic and adding a target touches one file:

```rust
#[cfg(target_os = "linux")]   mod linux;
#[cfg(target_os = "linux")]   pub use linux::install;
#[cfg(target_os = "windows")] mod windows;
#[cfg(target_os = "windows")] pub use windows::install;
// every consumer just calls install()
```

**Scope platform-only dependencies with `[target.'cfg(...)'.dependencies]`** so Cargo never compiles a Windows-only crate for Linux (saving build time and avoiding link errors on hosts lacking the platform libs):

```toml
[target.'cfg(windows)'.dependencies]
winreg = "0.10"
[target.'cfg(not(windows))'.dependencies]
libc = "0.2"
```

For reproducible multi-target release builds use **`cross`** (Docker-backed) instead of hand-managed linkers and sysroots — swap `cargo` → `cross build --target ...`. When a default image is insufficient, point one target at a custom image via a minimal, version-controlled `Cross.toml` rather than maintaining bespoke Dockerfiles:

```toml
# Cross.toml
[target.x86_64-pc-windows-gnu]
image = "my_image:tag"
```

## Build profiles

Override only what you need in profiles rather than changing defaults. Toggle dev-vs-release code with `#[cfg(debug_assertions)]` (true for `cargo build`, false for `--release`) instead of consumer-facing features.

**For size-minimized standalone binaries**, combine these — each contributes independently (smaller code, cross-crate dead-code elimination, maximal inlining, no unwinding machinery). Use `cargo-bloat` to find which crates dominate size.

```toml
[profile.release]
opt-level = "z"      # size over speed
lto = true           # cross-crate dead-code elimination
codegen-units = 1    # maximal cross-function optimization
panic = "abort"      # drop unwinding machinery
```

## `no_std`

Many `std` items just re-export `core`/`alloc`, so migration is cheap, but the only reliable guard is a cross-compile CI step (`cargo build --target thumbv6m-none-eabi`). With heap, swap `HashMap`/`HashSet` (std-only, need OS entropy) for `BTreeMap`/`BTreeSet` (in `alloc`); in tight-memory contexts, `try_reserve` before pushing to a `Vec` to handle OOM without aborting.

## CI gates

Make these build-breaking so reviewers never police trivia, and run them on every push on a clean machine — manual local runs break focus and miss optimization-only bugs:

- `cargo fmt --check`, `cargo clippy -- -Dwarnings`, `cargo check`, `cargo test --all`, and a `cargo build --release`. Clippy catches non-idiomatic patterns the compiler accepts (e.g. a hardcoded `3.1415` instead of `std::f64::consts::PI`).
- Pin the toolchain via `rust-toolchain.toml` (`channel = "1.70"`, not `"stable"`) so upgrades are explicit, reviewable changes.
- If you claim an MSRV, test on that exact version — an unverified MSRV silently rots.
- Build every meaningful feature combination (`--no-default-features`, `--all-features`), not just defaults.
- For libraries, also run with the lockfile removed (`rm -f Cargo.lock && cargo test`) to catch breakage from newer dependency releases that downstream users will actually see.
- Regenerate any checked-in generated code and fail on a diff (`git diff --exit-code`).
