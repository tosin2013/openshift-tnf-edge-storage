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
