# Validation Task 1: Provider Config Schema Integrity

## Scope
Validate that the three provider config JSON files are correct, complete, and internally consistent.

## Files to Review
- `profiles/default/defaults/providers/claude.json`
- `profiles/default/defaults/providers/codex.json`
- `profiles/default/defaults/providers/gemini.json`
- `profiles/default/defaults/settings.default.json`

## Checks

### Structure Validation
- [ ] All three JSON files parse without errors
- [ ] Each has required fields: `name`, `display_name`, `executable`, `models`, `default_model`, `cli_args`, `capabilities`, `stream_parser`, `ide_dir`, `mcp_setup`, `env_key`, `permission_modes`, `default_permission_mode`
- [ ] `name` matches the filename (e.g. `claude.json` has `"name": "claude"`)
- [ ] `default_model` key exists in `models` for each provider
- [ ] Every model entry has `id` and `description`

### CLI Args Accuracy
- [ ] Claude: verify `--model`, `--output-format stream-json`, `--print`, `--verbose`, `--session-id`, `--no-session-persistence` match actual Claude CLI help (`claude --help`)
- [ ] Claude: verify `cli_args.permissions_bypass` (`--dangerously-skip-permissions`) and `permission_modes` entries (`--permission-mode auto`) match Claude CLI
- [ ] Codex: verify `-m`, `--json`, exec subcommand match actual Codex CLI help (`codex exec --help`)
- [ ] Codex: verify `permission_modes` entries (`--dangerously-bypass-approvals-and-sandbox`, `--full-auto`) match Codex CLI
- [ ] Gemini: verify `-m`, `--output-format stream-json`, `-p` prompt flag match actual Gemini CLI help (`gemini --help`)
- [ ] Gemini: verify `permission_modes` entries (`-y`, `--approval-mode auto_edit`) match Gemini CLI

### Model IDs
- [ ] Claude model IDs are current (check against `claude --help` or Anthropic docs)
- [ ] Codex model IDs are valid OpenAI Codex models
- [ ] Gemini model IDs are valid Google Gemini models

### Capabilities
- [ ] Claude: `session_id: true`, `persist_session: true`
- [ ] Codex: `session_id: false`, `persist_session: false`
- [ ] Gemini: `session_id: false`, `persist_session: false`

### Permission Modes
- [ ] Each provider has `permission_modes` with at least one mode
- [ ] Each mode has `display_name`, `description`, `cli_args`
- [ ] `default_permission_mode` references a valid key in `permission_modes`
- [ ] Claude `auto` mode has `restrictions.excluded_models` containing `["Haiku"]`

### Settings
- [ ] `settings.default.json` has `"provider": "claude"` at top level
- [ ] `settings.default.json` has `"permission_mode": null` at top level
- [ ] Adding `"provider"` didn't break any existing fields

## How to Test
```bash
# Parse all three configs
pwsh -c "Get-Content profiles/default/defaults/providers/claude.json | ConvertFrom-Json"
pwsh -c "Get-Content profiles/default/defaults/providers/codex.json | ConvertFrom-Json"
pwsh -c "Get-Content profiles/default/defaults/providers/gemini.json | ConvertFrom-Json"

# Verify CLIs match
claude --help
codex exec --help
gemini --help
```
