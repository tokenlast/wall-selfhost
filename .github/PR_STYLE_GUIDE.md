# Pull request style guide

Adapted from the Unlocks Git workflow and pull request template.

## Commit messages and PR titles

Use Conventional Commits: `type(scope): short imperative description`.

- Prefer `feat`, `fix`, `refactor`, `perf`, `docs`, `test`, or `chore`.
- Use a scope that names the affected subsystem.
- Example: `docs(contributing): document pull request conventions`.
- Older history may predate this convention; do not rewrite it.

## Pull request descriptions

Fill in `.github/pull_request_template.md`:

- **What and why:** explain the change and the problem it solves; link an issue when available.
- **How it was tested:** list the actual commands and results, plus relevant manual checks. Distinguish passed, failed, blocked, and not-run checks. Use this repository's documented checks, not another project's commands.
- **Production impact:** identify backend, data, messaging, configuration, and deployment effects. Record setting names only, never secret values. State explicitly when the change is documentation-only.

## Workflow

Work on a branch targeting this repository's intended default branch. Follow existing repository instructions and require applicable tests and required CI checks to pass before merging. Preserve concurrent work and do not rewrite pushed history or bypass protections.

These style conventions do not grant permission to merge, deploy, change settings, or send messages. Existing project-specific instructions and the user's authorization still apply.
