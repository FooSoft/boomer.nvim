# boomer.nvim

A minimal Neovim chat buffer for **Codex** (App Server protocol), **GitHub
Copilot CLI** and other **ACP** agents. Requires Neovim 0.12+ and an installed,
authenticated agent.

```sh
nvim --cmd 'set runtimepath+=/path/to/boomer.nvim' -c Boomer
```

`:Boomer` opens a vertical split (or any side, or a float) with a native prompt
buffer, in Insert mode. Type after `Prompt: ` and press **Enter** to send;
**Shift-Enter** adds a line. Replies stream above the
prompt while you type. Enter during a turn queues the prompt; queued prompts are
sent one per turn. **Ctrl-C** cancels the active turn and returns queued prompts
to the draft. Full documentation: `:help boomer`.

Commands work as `:Boomer {command}` (with completion) or typed in the prompt as
`/command` (with `<C-x><C-o>` or `<C-n>` completion; `//text` sends a literal `/text`):

| Command | Action |
| --- | --- |
| `:Boomer` | Open or focus the chat |
| `/model [id]`, `/effort [level]` | Pick or set the model / reasoning effort |
| `/mode [mode]` | Pick or set the mode, e.g. `/mode plan` (Codex), `/mode agent` (leaves Copilot's plan mode) |
| `/settings` | Pick any session setting the agent offers |
| `/permissions [preset]` | Read Only / Default / Full Access (Codex); default / assisted / allow-all (Copilot) |
| `/resume [id]`, `/new` | Load a saved session / start a new one |
| `/agent [name]` | Switch to another agent profile |
| `/compact [focus]` | Compact the conversation |
| `/usage` | Context, token and cost usage |
| `/help` | List commands, including user and agent commands |
| `:Boomer cancel`, `:Boomer close` | Cancel the turn / stop the agent |

Slash commands advertised by ACP agents (such as Copilot's `/plan`) are sent to
the agent; unknown ones are not sent.

The chat window's winbar shows the agent, model, mode, state and context use, aligned
to the right, e.g. `copilot | Claude Sonnet 4.5 (high) | Plan | ready | ctx 42%`. For statusline
plugins use `require('boomer').statusline()` or `.status()`; `User BoomerStatus`
and `User BoomerTurnDone` autocommands report changes. In the chat, `<S-Tab>` picks the mode
(e.g. to leave Copilot's plan mode). No global keymaps are set;
map commands directly, e.g. `vim.keymap.set('n', '<Leader>a', '<Cmd>Boomer<CR>')`.
Run `:checkhealth boomer` to check agents.

## Configuration

Optional; applies to the next chat. See `:help boomer-config`.

```lua
require('boomer').setup({
    agent = 'codex', -- default profile
    agents = { -- merged with the built-in profiles (see below)
        copilot = { model = 'claude-sonnet-4.5', effort = 'high', mode = 'plan' },
        myagent = { protocol = 'acp', command = 'my-agent', args = { 'acp' } },
    },
    commands = { -- user slash commands; `false` disables a built-in
        review = { desc = 'Review the diff', prompt = 'Review `git diff`. $ARGUMENTS' },
    },
    winbar = true, -- or false, or function(status) -> winbar string
    window = { -- 'right', 'left', 'top', 'bottom' or 'float'; sizes < 1 are fractions
        position = 'right', width = 0.5, height = 0.5,
        float = {}, -- extra nvim_open_win() config, e.g. { border = 'rounded' }
    },
    labels = { prompt = 'Prompt:', agent = 'Agent:' },
})
```

A profile has `protocol` (`'codex'` or `'acp'`), `command`, `args`, `env`, a
message `label` (overrides `labels.agent`), and defaults for new sessions:
`model`, `effort`, `mode` and ACP `options`.

Built-in profiles: `codex` (`codex app-server`) and the ACP agents `copilot`,
`auggie`, `claude` (`claude-agent-acp`), `cline`, `cursor` (`cursor-agent`),
`gemini`, `goose`, `kimi`, `kiro` (`kiro-cli`), `opencode`, `qwen` and `vibe`
(`vibe-acp`); see `:help boomer-agents`. `/agent` offers the installed ones.
The agent runs in Neovim's working directory.

The agent runs with your environment, configuration and credentials, and enforces
its own sandbox. Boomer never adds auto-approval flags.

## Development

```sh
make test                                     # fake agents; no login or network
make test FILTER=sessions                     # tests whose name contains "sessions"
make test-real BACKEND=codex                  # initialize a real CLI, no inference
make test-real BACKEND=copilot REAL_ARGS=--allow-inference   # uses quota
```

Set `NVIM_BIN` to test with another Neovim. Without `make` (on Windows, say), run
`nvim --clean --headless -l tests/run.lua [filter]`. Fake agents are described in
[tests/scenarios/README.md](tests/scenarios/README.md).

## License

MIT
