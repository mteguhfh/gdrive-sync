# Contributing to gdrive-sync

Thanks for taking the time to contribute. This project is a single bash script plus a
test suite, so the bar for a change is low: keep it small, keep the tests green.

## Ways to help

- Report a bug or a confusing error message.
- Improve the documentation or the wording of a message.
- Add a test for a case you hit in real use.
- Send a small pull request that fixes one thing.

## Development setup

Requirements:

- Linux with `bash`, `rclone >= 1.66`, `systemd` (for the timer parts), `curl`.
- No Google account is needed to run the tests.

```bash
git clone https://github.com/mteguhfh/gdrive-sync.git
cd gdrive-sync
./tests/run_tests.sh
```

The tests point `REMOTE_NAME` at a local directory, which rclone treats as the `local`
backend, so a full sync runs inside a temporary folder.

Run the checks the CI runs:

```bash
bash -n gdrive-sync.sh
bash -n tests/run_tests.sh
shellcheck --severity=error gdrive-sync.sh tests/run_tests.sh
./tests/run_tests.sh
```

## Code guidelines

- Bash only, no new runtime dependencies unless there is no reasonable alternative.
- `set -Eeuo pipefail` stays on. Do not weaken it.
- User-facing messages are in Indonesian, short and specific. Say what failed and what to
  run next.
- Never add a default that can delete data. Anything destructive must be opt-in and
  documented.
- Quote every variable: `"$VAR"`, `"${arr[@]}"`.
- Add a test for every behaviour change. The suite prints `passed=N failed=M`; CI fails
  when `M > 0`.

## Adding a feature

1. Open an issue describing the use case first, unless the change is a one-liner.
2. Keep the change focused. Separate pull requests for separate ideas.
3. Update `README.md` and `gdrive-sync.conf.example` when you add a config option or a
   command.
4. Run the full test suite before pushing.

## Commit messages

Short imperative subject line, present tense:

```
add --exclude flag to sync
fix empty sources.txt blocking setup
docs: explain how to add a folder
```

Add a body when the reason for the change is not obvious from the diff. Explain *why*,
not *what*.

## Reporting a bug

Include:

- output of `./gdrive-sync.sh config`
- output of `rclone version`
- the failing command and its full output
- the last 50 lines of `~/.local/state/gdrive-sync/gdrive-sync.log`

Remove tokens, file names, and anything private before pasting logs. Never paste the
contents of `~/.config/rclone/rclone.conf`.

## License

By contributing you agree that your contribution is licensed under the MIT License, as
described in [LICENSE](LICENSE).