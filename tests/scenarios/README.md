# Fake agents

`tests/support/fake` stands in for `codex` or `copilot`: it ignores its arguments
and runs `tests/support/fake.lua` under `nvim -l` (`$BOOMER_NVIM`, default `nvim`)
with the scenario file named by `$BOOMER_SCENARIO`. On Windows, `fake.cmd` does
the same (like an npm shim, it runs the peer as a child of `cmd.exe`). Scenarios
spell the working directory `"/tmp"`; the runner replaces it with the real one.
The peer has its own framing and JSON-RPC code, so a plugin bug is not mirrored in
the tests. On a mismatch it writes `scenario step N: ...` to stderr and exits 2;
the test runner shows this stderr on failure.

```json
{
  "version": 1,
  "profile": "acp-v1",
  "steps": [
    {"op":"expect_request","message":{"id":{"capture":"init"},"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{},"clientInfo":{"name":"boomer","version":"0.1.0"}}}},
    {"op":"send_response","message":{"id":{"ref":"init"},"result":{"protocolVersion":1,"agentCapabilities":{},"authMethods":[]}},"fragments":[1,2,7]}
  ]
}
```

`profile` selects the wire format: `acp-v1` sends and requires `"jsonrpc": "2.0"`,
`codex-v2` omits it. Messages match exactly apart from key order; `{}` and `[]`
differ, as do missing and `null`. `{"capture": name}` binds a value (such as a
request ID) and `{"ref": name}` substitutes it later.

Operations:

- `expect_request`, `expect_notification`, `expect_response`: wait for `message`.
- `parallel`: wait for all of `messages`, in any order.
- `send_request`, `send_response`, `send_notification`: write `message`, or all of
  `messages` in one write. `fragments` splits the write into chunks of these sizes.
- `write_raw`: write `data` to stdout as is; `stderr`: write `data` to stderr.
- `delay`: wait `ms` while still reading input.
- `close_stdout`: close stdout but keep reading stdin.
- `exit`: exit with `code` after `ms` (default 10).

Each step must finish within `step_timeout_ms` (default 2000) and the scenario
within `timeout_ms` (default 10000). Unexpected messages, traffic after the last
step, or EOF before it fail the peer; otherwise it exits 0 on stdin EOF. The
`ignore_eof` and `ignore_sigterm` flags make it resist shutdown so the client must
kill it.

`tests/run.lua` loads these files and often edits or concatenates their steps for
a particular case.
