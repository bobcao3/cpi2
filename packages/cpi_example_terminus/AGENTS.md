# Terminus example checks

| Rule                                                                                                            | Enforcement                                                                                                                                                   |
| --------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| In terminal-output and history CLI fixtures, the expected output marker must not occur in the shell command.    | `tests/test_cli.py` checks each command and checks the marker in a later model prompt.                                                                        |
| The Worker requests its observation budget. Large output must complete without requiring full-history transfer. | `tests/test_cli.py` runs 700 KB and 2 MiB output cases through the real CLI. Ghostmux capture tests check head/tail order, byte counts, and UTF-8 boundaries. |
