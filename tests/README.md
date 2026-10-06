# Save and restore checks

Run the checks with WezTerm and an installed `age` binary. `age-keygen` must be in the same directory as `age`.

```sh
python3 tests/test_state.py --age /path/to/age
```

The checks use temporary state files and a temporary encryption key. They verify encrypted save/load, deletion, failed loads, directory creation, and save notifications.

On macOS or Linux, add `--gui` to test restoring a workspace with two tabs, split panes, titles, and scrollback in a separate GUI process. The test runs `/bin/cat`, closes that process afterward, and removes its temporary files.
