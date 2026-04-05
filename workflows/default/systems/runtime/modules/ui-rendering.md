# ui-rendering.ps1 — Deprecation Notes

## Status: DEPRECATED

Most functions have been moved to `DotBotTheme.psm1`. This file is retained only for backward compatibility.

## Retained Functions

- **`Strip-Ansi`** — Removes ANSI escape codes from strings. Still used by callers that need plain-text output.
- **`Wrap-Text`** — Wraps text to a maximum width. Still used for terminal output formatting.

## Deprecated Functions (use DotBotTheme equivalents)

| Old Function | Replacement |
|---|---|
| `Get-VisibleWidth` | `Get-VisualWidth` in DotBotTheme.psm1 |
| `Format-BoxLine` | Card/Panel functions in DotBotTheme.psm1 |

## Future

Once all callers of `Strip-Ansi` and `Wrap-Text` are migrated to DotBotTheme equivalents, this file can be removed entirely.
