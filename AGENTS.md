# Repository workflow

## Landing changes

- Treat `main` as a protected branch. Do not push commits directly to it.
- Start work from the latest `origin/main` on a branch named `codex/<short-description>`.
- Before opening or updating a pull request, incorporate the latest `origin/main` and resolve conflicts locally.
- Commit only intentional source, test, documentation, and configuration changes. Keep build products, coverage output, derived data, and other generated artifacts out of commits.
- Every changed or newly added line of production code must have matching automated test coverage. Add or update those tests in the same change; do not leave new or modified behavior untested.
- Run the relevant focused tests while developing. Before requesting merge, run the complete Swift test suite and build both the iOS and macOS app targets when the change affects shared or app code.
- Push the branch to `origin`, open a pull request targeting `main`, and summarize both the behavior change and verification performed.
- Let required GitHub checks finish successfully before merging. If a check fails, inspect and fix the cause on the same branch rather than bypassing branch protection.
- After merging, verify that `origin/main` contains the pull request and report the pull request link and final commit.
