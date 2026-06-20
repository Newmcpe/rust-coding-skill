# rust-coding-skill

A [Claude Code](https://docs.claude.com/en/docs/claude-code) skill that makes coding agents write Rust the way an experienced Rust developer would — instead of Rust that merely compiles.

Agents reach for whatever they saw most in training: `&String` parameters, `.unwrap()` everywhere, manual index loops, `clone()` to dodge the borrow checker. This skill replaces those defaults with the actual idioms, and ends every task on a `cargo fmt` + `cargo clippy -D warnings` + `cargo test` gate, so the output is clippy-clean rather than clippy-bait.

## How it works

The skill uses progressive disclosure. `SKILL.md` is a lean core — an operating procedure, a list of non-negotiables, and a routing table. The detail lives in `references/`, and the agent opens only the file the current task needs:

| Reference | Covers |
|---|---|
| `ownership-borrowing` | moves, borrows, lifetimes, slices, avoiding needless clones |
| `error-handling` | `Result`/`Option`, `?`, custom errors, `thiserror`/`anyhow`, when to panic |
| `data-modeling` | structs, enums, newtypes, making invalid states unrepresentable, const generics |
| `traits-generics-lifetimes` | bounds, associated types, static vs `dyn`, AFIT, conversions |
| `collections-iterators` | iterator chains over loops, `collect`, the `entry` API |
| `project-structure` | Cargo, modules, editions, features, semver, workspaces, CI |
| `smart-pointers` | `Box`/`Rc`/`Arc`/`RefCell`, interior mutability, `Drop`/RAII |
| `concurrency` | threads, channels, `Arc<Mutex>`, atomics & ordering, async |
| `testing` | unit/integration/doc tests, organization, fuzzing |
| `api-design-naming` | naming, constructors, receiver choice, public-API ergonomics |
| `unsafe-ffi` | `unsafe` contracts, raw pointers, soundness, FFI, `no_std` |
| `idioms-antipatterns` | the do-this-not-that catch-all |
| `security-tooling` | idiomatic Rust for network/security tooling (engineering, not weaponization) |

Each reference is a dense set of rules with short good-vs-bad code blocks and the *reasoning* behind each one, not a wall of ALWAYS/NEVER.

## Install

Clone and drop the skill folder into your Claude Code skills directory:

```sh
git clone https://github.com/Newmcpe/rust-coding-skill.git
cp -r rust-coding-skill/rust-coding-skill ~/.claude/skills/
```

It triggers automatically on Rust work — writing, refactoring, reviewing, fixing borrow-checker errors, cleaning up clippy lints. No flag needed.

## Verification gate

The skill requires the agent to actually run the checks, not just claim success. There's a bundled gate it can invoke:

```sh
rust-coding-skill/scripts/check.sh    # POSIX
rust-coding-skill/scripts/check.ps1   # Windows
```

Both run `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, and `cargo test`, stopping on the first failure.

## Where the rules come from

The references were distilled from six Rust books — *The Rust Programming Language*, *Effective Rust*, *The Rustonomicon*, *Rust for Rustaceans*, *Black Hat Rust*, and *Rust in Action* — then deduplicated and merged by topic. Every code snippet that was edited afterwards is compile-checked against rustc 1.96. The book text itself is **not** included in this repo (it's copyrighted); only the distilled, reworded guidance is.

A note on `security-tooling.md`: it covers the defensible engineering craft for network and security tools (async clients, bounded concurrency, parsing untrusted input, secret handling, static binaries). It deliberately stops short of offensive tradecraft. Use it within authorized engagements.

## License

[WTFPL](LICENSE) — do what the fuck you want to.
