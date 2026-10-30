# Step fixtures (HARNESS.md H3)

Hand-written on 2026-10-30, not yet recorded from live runs:

- `codex-steps.jsonl`: app-server notifications, shaped after the JSON schema that
  `codex app-server generate-json-schema` prints for codex-cli 0.165.0-alpha.1.2
  (`ThreadItem`, `CommandExecutionOutputDeltaNotification`, `TurnDiffUpdatedNotification`).
- `claude-steps.jsonl`: Claude Code `--output-format stream-json` lines (`assistant` with
  `tool_use`, `user` with `tool_result`), as the Agent SDK message types describe them.
- `cursor-steps.jsonl`: Cursor agent `tool_call` events, following the shapes AgentDesk's
  Cursor parser already handled (`<name>ToolCall` with `args` and `result.success`);
  `rejected` and `exitCode` are assumptions.

Replace each with a recorded run (one turn per CLI that reads, edits and runs a failing
command) when live checks are allowed; the tests should keep passing.
