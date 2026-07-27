## Onboarding

This project uses an `onboard.yml` manifest for automated setup. The manifest
declares prerequisites, configuration prompts, and validation checks needed
before the project can be deployed.

### For AI Agents

Read `onboard.yml` and walk the user through setup interactively, following
these phases in order. If the user prefers to handle setup themselves, recommend
they run `./bootstrap.sh` instead.

#### Phase 0 — Discover the manifest

Find `onboard.yml` in the project root. Display the project `name` and `description`.
If the manifest has a `modes` section, ask the user: "Are you a maintainer/contributor
(dev) or an end user looking to deploy (prod)?" Default to prod.

#### Phase 1 — Detect platform

On Linux read `/etc/os-release` and map `ID`+`VERSION_ID` to a platform key:
`rhel8`, `rhel9`, `rhel10`, `fedora`, `debian`. On macOS use `macos`. These keys
select the correct install command from each prerequisite's `install` map.

#### Phase 2 — Prerequisites

For each entry in `prerequisites`:

1. Run `check_command`. If exit 0, the tool is present.
2. If `version_regex` and `min_version` are set, extract the version and compare
   using dot-separated numeric comparison. Treat lower versions as needing upgrade.
3. If missing or outdated, look up the install command for the detected platform key.
   Fall back to the `fallback` key if no match. Confirm with the user before running
   `sudo` commands.
4. Re-check after install to verify success.

In **dev mode**, also process `modes.dev.extra_prerequisites` after the base list.

All prerequisites must succeed before continuing.

#### Phase 3 — Configuration wizard

Load `config.output_file` if it exists (otherwise manifest defaults). Show a
summary of current values plus status of secrets file, pull secret, and
AgnosticD. Ask the user to **Keep**, **Edit**, or **Reset** to defaults.

On Edit/Reset, prompt each `config.prompts` entry using the current value as
the default (Enter keeps it). Validate `choices` and `required` as usual.
Write a flat YAML file to `config.output_file` with one `key: value` per line.
If `config.gitignore` is true, ensure the file path is in `.gitignore`.

#### Phase 4 — Setup steps

For each entry in `setup_steps`:

1. If `prompt_var` is set and not already collected by the config wizard, prompt
   for the value. Store it for `${variable}` substitution.
2. Run the `check` command (with variable substitution). If exit 0, skip (already done).
3. Otherwise run the `action` command.

After setup, assist with secrets: report whether the secrets file is missing,
still has placeholders, or looks configured, and offer to open it in `$EDITOR`.

#### Phase 5 — Validation and readiness gate

For each entry in `validation`:

1. Substitute `${variable}` references using config values.
2. Run the `command`. Exit 0 = PASS.
3. If `required: true` and failed = FAIL. If `required: false` and failed = WARN.
4. On failure, show `fail_message` (with variable substitution).

Compute a readiness score: `X/Y required checks passed (N warnings)`.

- All required checks pass = ready for deployment.
- Any required check fails = **BLOCKED**. Do not deploy.
- Warnings are informational and do not block.

#### Phase 5b — Quota checks

If the manifest defines `quota_checks`, check cloud resource quotas before
deploying. For each entry, run `limit_command` and `usage_command` (with variable
substitution), compute `available = limit - usage`, and compare with `needed`.

`needed` may be a plain integer or an arithmetic expression using config
variables (for example `30 + 22 * ${num_students}`). Substitute variables first,
then evaluate with bash arithmetic. All quota checks must pass.

#### Phase 6 — Post-setup

Display `post_setup.message` with `${variable}` references substituted.

In **prod mode**, if all required checks passed and `modes.prod.post_validation_command`
is defined, ask the user if they want to deploy now.

### Variable substitution

Fields in `setup_steps`, `validation`, and `post_setup` use `${variable}` syntax.
Variables resolve from values collected in setup step prompts and config prompts
(the `key` field). Resolution order: setup step `prompt_var` values first, then
config prompt values.

### Dev vs prod modes

| Mode | Audience | Behavior |
|------|----------|----------|
| dev | Maintainers, contributors | Base prerequisites + `modes.dev.extra_prerequisites`. No deploy. |
| prod (default) | End users | Base prerequisites, full config, validation, optional deploy via `modes.prod.post_validation_command`. |

### For humans without AI

Run the bootstrap script directly:

```bash
./bootstrap.sh                    # interactive wizard (load/edit config, secrets, validate)
./bootstrap.sh --mode dev         # maintainer/contributor setup
./bootstrap.sh --non-interactive  # use config.yml or manifest defaults (CI/automation only)
./bootstrap.sh --check-only       # validation and readiness check only
```

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:970c3bf2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   bd dolt push
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->

<!-- BEGIN BEADS CODEX SETUP: generated by bd setup codex -->
## Beads Issue Tracker

Use Beads (`bd`) for durable task tracking in repositories that include it. Use the `beads` skill at `.agents/skills/beads/SKILL.md` (project install) or `~/.agents/skills/beads/SKILL.md` (global install) for Beads workflow guidance, then use the `bd` CLI for issue operations.

### Quick Reference

```bash
bd ready                # Find available work
bd show <id>            # View issue details
bd update <id> --claim  # Claim work
bd close <id>           # Complete work
bd prime                # Refresh Beads context
```

### Rules

- Use `bd` for all task tracking; do not create markdown TODO lists.
- Run `bd prime` when Beads context is missing or stale. Codex 0.129.0+ can load Beads context automatically through native hooks; use `/hooks` to inspect or toggle them.
- Keep persistent project memory in Beads via `bd remember`; do not create ad hoc memory files.

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.
<!-- END BEADS CODEX SETUP -->
