# AltTab AeroSpace Workspace Cards

A private AltTab fork with a custom AeroSpace module.

The module groups all windows from each managed AeroSpace workspace into a single card in the AltTab interface. Selecting the card activates the corresponding workspace.

![Workspace card preview](workspace-card.png)

## Behavior

- Workspaces 2–5 appear as one card per non-empty workspace.
- Windows in the default blank workspace remain regular AltTab cards.
- Native macOS fullscreen windows remain separate window cards.
- Workspace cards support focus and group window actions.

## Module

`src/reborn-modules/AeroSpaceWorkspaceCards/AeroSpaceWorkspaceCards.swift`

## Build

```sh
chmod +x BUILD_AND_INSTALL.command
./BUILD_AND_INSTALL.command
```

Requires macOS, Xcode, and AeroSpace installed at `/opt/homebrew/bin/aerospace`.

## Status

Private experimental integration. Build and runtime testing are required after changes.

## License

GNU General Public License v3.0. See [LICENCE.md](LICENCE.md).
