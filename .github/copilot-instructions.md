# Copilot instructions for boomer.nvim

Neovim 0.12+ plugin (pure Lua, no dependencies) that provides a chat buffer for
coding agents: Codex via its App Server protocol, and GitHub Copilot CLI and
other agents via ACP (Agent Client Protocol).

## Build, test, lint

There is no build step. Tests are self-contained Lua scripts run by headless
Neovim with no test framework.

```sh
make test                          # all offline tests (fake agents, no network)
make test FILTER=sessions          # only tests whose name contains "sessions" (plain substring)
nvim --clean --headless -l tests/run.lua sessions   # same, without make (e.g. Windows)
NVIM_BIN=/path/to/nvim make test   # test another Neovim
make test-real BACKEND=codex       # opt-in: initialize a real, authenticated CLI; no inference
make test-real BACKEND=copilot REAL_ARGS=--allow-inference   # sends a prompt; uses quota
```

CI (`.github/workflows/test.yml`) runs `make test` on Linux and Windows with
Neovim 0.12. Formatting follows `.stylua.toml` (StyLua, Lua 5.1 syntax,
4-space indent, 100 columns, single quotes, `collapse_simple_statement = "Never"`:
keep guards and callbacks expanded across lines rather than one-liners).

## Architecture

- `plugin/boomer.lua` defines only `:Boomer`; everything else is lazily required.
- `lua/boomer/init.lua` owns the single global chat (`boomer.Chat`): the
  client, its session, the view, the permission queue and the prompt queue. All
  `:Boomer` subcommands and `/slash` commands dispatch here. The **adapter
  interface** (`boomer.Client`) and the **callbacks** adapters report through
  (`boomer.Callbacks`) are documented as LuaCATS classes at the top of this file.
- Adapters `lua/boomer/codex.lua` and `lua/boomer/acp.lua` implement
  `boomer.Client`. `config.protocols` maps a profile's `protocol` to its adapter
  module. Their semantics differ:
  - Codex: a session is a thread; model/effort/mode/permissions are *staged
    locally* and sent with the next `turn/start`.
  - ACP: a prompt is one long-lived `session/prompt` request with
    `session/update` notifications streaming; settings are changed on the agent
    immediately. Updates arriving before `session/new` returns are buffered in
    `early` and replayed.
- `lua/boomer/rpc.lua`: newline-delimited JSON-RPC over `vim.system()` stdio,
  shared by both adapters. `jsonrpc = true` adds the `"jsonrpc": "2.0"` marker
  (ACP requires it; Codex omits it). libuv callbacks are scheduled onto the main
  loop, so all handlers run on the main loop and need no locking.
- `lua/boomer/util.lua` defines the backend-neutral `boomer.Setting` shape.
  Adapters translate protocol-specific settings into it (`setting_list()`,
  `settings()`, `configure()`), so `init.lua` can list/complete/change model,
  effort, mode and permissions without knowing the protocol. Categories use
  ACP's names (`effort` → `thought_level`).
- `lua/boomer/view.lua`: the chat is a native `buftype=prompt` buffer.
  Neovim's `:` mark is the start of the editable draft; everything above it is
  output. Highlights use extmarks in two namespaces (`boomer` for transcript,
  `boomer.prompt` for live prompt decorations); nothing else tracks positions.
- `lua/boomer/commands.lua`: slash-command parsing, the `builtins` table, user
  prompt templates and completion. Each builtin's `gate` names a precondition
  checked by `blocked()` in `init.lua` (`none`, `session`, `idle`, `queue`,
  `switch`, `agent`). A builtin `name` is executed by calling `M[name]` in
  `init.lua`, so adding one means a `builtins` entry plus a matching
  `M.<name>` function.
- `lua/boomer/config.lua`: built-in agent profiles merged field-by-field with
  user profiles; options are validated eagerly in `setup()`.
- `lua/boomer/status.lua`: the status table rendered for winbar/statusline/
  `/usage`, announced via coalesced `User BoomerStatus` autocmds.

## Conventions

- **Stale-callback guards**: async callbacks check `c.closed`, `c.dead`,
  `chat == c` or `c.view == view` before acting, because the chat, session or
  view may have been replaced. Pickers use a generation token (`c.picks`) and
  drop stale answers. Follow this pattern for any new async path.
- Errors passed between adapters and the chat are `{ message = string }` tables;
  callbacks are `cb(err, result)`. Adapter status updates are merged into the
  chat state, with `vim.NIL` clearing a field.
- Permission requests (`boomer.Permission`) are answered at most once; adapters
  set `done` when they settle them on cancel or turn end.
- User-facing warnings go through `vim.notify` with `{ title = 'Boomer' }`.
  No global keymaps are set; Boomer never adds auto-approval flags to agents.
- Must work on Windows: see the case-insensitive env handling in `rpc.lua` and
  `tests/support/fake.cmd`. `*.cmd` files use CRLF (`.gitattributes`).
- User-visible behavior is documented in both `README.md` and `doc/boomer.txt`
  (Vim help, `*boomer-...*` tags); update both when commands, options or
  status fields change.

## Tests

- `tests/run.lua` drives the real plugin against a **fake agent**:
  `tests/support/fake` (or `fake.cmd`) runs `tests/support/fake.lua` under
  `nvim -l`, replaying the JSON scenario named by `$BOOMER_SCENARIO`. The fake
  has its own framing/JSON-RPC code on purpose so plugin bugs aren't mirrored.
  Scenario format and ops are documented in `tests/scenarios/README.md`.
- Scenarios match messages exactly (except key order; `{}` ≠ `[]`, missing ≠
  `null`). `profile` is `acp-v1` or `codex-v2`. Use `{"capture": name}` /
  `{"ref": name}` for IDs. The working directory is spelled `"/tmp"` and
  replaced at load time.
- Tests are registered with `test(name, fn)`. Helpers in `run.lua`: `load()`
  a scenario, splice with `steps(a, from, to, b, from, ...)`, `open()`/`play()`
  to start the chat against the fake, `send()`, `turn()`, `ready()`,
  `await()`, and `finish()` — which closes the chat and asserts the fake played
  the **entire** scenario (exit 0). Tests often edit loaded scenarios inline
  rather than adding new JSON files.
- `vim.notify`, `nvim_echo` and `vim.ui.select` are stubbed; `finish()` makes
  any unexpected picker an error. Rpc kill timeouts are shortened for tests.
