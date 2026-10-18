# todo-core

Required local Rust core for TodoAnxiety.nvim. It speaks MessagePack-RPC over
stdin/stdout and is started with `jobstart(..., { rpc = true })`.

The Lua plugin has **no fallback**: a missing, incompatible or crashed core is a
hard startup error.

## Build

```sh
cargo build --release --manifest-path core/Cargo.toml
```

Or:

```sh
./scripts/build-core.sh
```

The plugin looks for the binary in this order:

1. `core.bin` from `require("todo").setup({ core = { bin = "..." } })`
2. `$TODO_CORE_BIN`
3. `core/target/release/todo-core`
4. `core/target/debug/todo-core`
5. `todo-core` on `$PATH`

## Protocol

Every request is a standard MessagePack-RPC request:

```text
[0, msgid, method, params]
```

Every reply:

```text
[1, msgid, error, { ok = true, value = ... }]
```

Methods currently exposed: `core.hello`, `core.health`, `core.urgency`,
`core.urgency_batch`, `core.recurrence_normalize`, `core.recurrence_next`,
`core.duration_parse`, `core.shutdown`.
