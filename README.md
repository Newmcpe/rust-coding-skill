# rust-coding-skill

A portable, idiomatic-Rust ruleset for agentic coding agents — it makes them write Rust the way an experienced Rust developer would, instead of Rust that merely compiles. Ships as a [Claude Code](https://docs.claude.com/en/docs/claude-code) skill **and** as drop-in rule files for Cursor, GitHub Copilot, Cline, Windsurf, and anything that reads [`AGENTS.md`](https://agents.md) (Codex, Zed, Aider, Jules, …).

Agents reach for whatever they saw most in training: `&String` parameters, `.unwrap()` everywhere, manual index loops, `clone()` to dodge the borrow checker. This ruleset replaces those defaults with the actual idioms, and ends every task on a `cargo fmt` + `cargo clippy -D warnings` + `cargo test` gate, so the output is clippy-clean rather than clippy-bait.

## How it works

Progressive disclosure. A lean core — an operating procedure, a list of non-negotiables, and a routing table — lives in the entrypoint your agent reads. The detail lives in `rust-coding-skill/references/`, and the agent opens only the file the current task needs. Same rules, many front doors:

| Agent | Reads |
|---|---|
| Claude Code / Agent Skills | `rust-coding-skill/SKILL.md` |
| Codex, Zed, Aider, Jules, … | `AGENTS.md` |
| Cursor | `.cursor/rules/idiomatic-rust.mdc` |
| GitHub Copilot | `.github/copilot-instructions.md` |
| Cline | `.clinerules` |
| Windsurf | `.windsurfrules` |

Every front door routes into the same reference set:

| Reference | Covers |
|---|---|
| `ownership-borrowing` | moves, borrows, lifetimes, slices, avoiding needless clones |
| `error-handling` | `Result`/`Option`, `?`, custom errors, `thiserror`/`anyhow`, when to panic |
| `data-modeling` | structs, enums, newtypes, making invalid states unrepresentable, const generics |
| `traits-generics-lifetimes` | bounds, associated types, static vs `dyn`, AFIT, conversions |
| `collections-iterators` | iterator chains over loops, `collect`, the `entry` API |
| `project-structure` | Cargo, modules, editions, features, semver, workspaces, CI |
| `smart-pointers` | `Box`/`Rc`/`Arc`/`RefCell`, interior mutability, `Drop`/RAII |
| `concurrency` | threads, scoped threads, channels, `Arc<Mutex>`, atomics & ordering, async |
| `testing` | unit/integration/doc tests, organization, fuzzing |
| `api-design-naming` | naming, constructors, receiver choice, public-API ergonomics |
| `unsafe-ffi` | `unsafe` contracts, raw pointers, soundness, FFI, `no_std` |
| `idioms-antipatterns` | the do-this-not-that catch-all |
| `security-tooling` | idiomatic Rust for network/security tooling (engineering, not weaponization) |

Each reference is a dense set of rules with short good-vs-bad code blocks and the *reasoning* behind each one, not a wall of ALWAYS/NEVER.

## Install / use

**Claude Code** — drop the skill folder into your skills directory; it triggers automatically on Rust work, no flag needed:

```sh
git clone https://github.com/Newmcpe/rust-coding-skill.git
cp -r rust-coding-skill/rust-coding-skill ~/.claude/skills/
```

**Any other agent** — the adapter files (`AGENTS.md`, `.cursor/rules/…`, `.github/copilot-instructions.md`, `.clinerules`, `.windsurfrules`) already ship in this repo and point at `rust-coding-skill/references/`. Either point your agent at a clone of this repo, or vendor the adapter you need plus the `rust-coding-skill/references/` folder into your own project.

## Verification gate

The ruleset requires the agent to actually run the checks, not just claim success. A bundled gate it can invoke:

```sh
rust-coding-skill/scripts/check.sh    # POSIX
rust-coding-skill/scripts/check.ps1   # Windows
```

Both run `cargo fmt --check`, `cargo clippy --all-targets -- -D warnings`, and `cargo test`, stopping on the first failure.

## Where the rules come from

The references were distilled from seven Rust books — *The Rust Programming Language*, *Effective Rust*, *The Rustonomicon*, *Rust for Rustaceans*, *Black Hat Rust*, *Rust in Action*, and *Rust Atomics and Locks* — then deduplicated and merged by topic. Every code snippet that was edited afterwards is compile-checked against rustc 1.96. The book text itself is **not** included in this repo (it's copyrighted); only the distilled, reworded guidance is.

A note on `security-tooling.md`: it covers the defensible engineering craft for network and security tools (async clients, bounded concurrency, parsing untrusted input, secret handling, static binaries). It deliberately stops short of offensive tradecraft. Use it within authorized engagements.

## License

[WTFPL](LICENSE) — do what the fuck you want to.
