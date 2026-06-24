# MST

MST combines BetterNBB, WindowBackdrop, Better Piechart, MACrosshair, and Key Rebinder into one app.

## Requirements

- macOS 14 or later
- Accessibility permission for global keybinds while another app is focused
- Screen Recording permission for screen-capture based overlays such as Better Piechart
- Karabiner-Elements for Key Rebinder

> If macOS blocks the app on first launch, right-click and choose **Open**, or go to **System Settings → Privacy & Security** and open the app from there.

## Installation

### DMG (recommended)

1. Open `MST-<version>-macOS.dmg.zip`.
2. Drag `MST.app` to Applications.
3. Open the app and grant any permissions MST asks for.

### Source installer ZIP

1. Unzip `MST-<version>-source-installer.zip`.
2. Double-click `compile_and_install.command`.
3. The installer builds and installs the app, then opens it.

### Build from source

```sh
swift build -c release
```

To create a local app bundle:

```sh
./scripts/build-app.sh
```

Output: `dist/MST.app`

## App Layout

The sidebar contains: Overview, BetterNBB, WindowBackdrop, Better Piechart, MACrosshair, and Key Rebinder.

- **Complex Mode** — full settings for the selected tool
- **Simple Mode** — a grid of large toggle buttons for quick access

## Global Keybinds

Each tool can have its own keybind to toggle its overlay or visibility after the tool has been started. Accessibility permission must be enabled for keybinds to work outside of MST.

- **BetterNBB** — show/hide the BetterNBB overlay
- **WindowBackdrop** — show/hide the backdrop
- **Better Piechart** — show/hide the piechart projector
- **MACrosshair** — show/hide the crosshair
- **Key Rebinder** — activate preset-specific hotkeys

## Features

### BetterNBB

A better overlay for NinjabrainBot.

- Start/stop the overlay
- Place and resize the overlay template
- Adjust prediction and eye throw row counts
- Choose which stronghold and eye throw columns are shown
- Hide 0% predictions, show NBB messages and movement hints
- Customize background, opacity, border, corner radius, and shadow

### WindowBackdrop

Draws a backdrop behind your Minecraft instance.

- Start/stop the backdrop
- Solid color or image backdrop
- Choose image fit behavior and empty-zone color
- Adjust opacity and blur
- Optionally cover the menu bar

### Better Piechart

Projects the Minecraft pie chart round and displays the e-counter.

- Start/stop the piechart projector
- Toggle projector with a keybind
- Keep projector always on top
- Select the pie area and tune template height, crop size, and circle fit
- Preview raw capture and corrected pie output

### MACrosshair

Draws a crosshair on the screen for MCSR Oneshot.

- Start/stop the crosshair
- Toggle with a keybind
- Pick from color presets
- Adjust line length, thickness, center dot, dot size, and opacity
- Offset the crosshair position and reset it

### Key Rebinder

Syncs Karabiner-Elements profiles and remaps from inside MST.

- Detect Karabiner connection status and open setup links when needed
- View and switch Karabiner profiles
- Add, rename, enable, disable, and delete presets
- Assign a global hotkey to each preset
- Rebind keyboard keys and mouse buttons through a visual layout
- Sync remaps back to Karabiner-Elements

## Changelog

### v2.0.0
- Added Key Rebinder with visual keyboard and mouse remapping through Karabiner-Elements
- Added per-preset hotkeys
- Added light mode
- New settings window
- Upgraded Better Piechart

## License

Copyright © 2026 ducky8x.

This project is licensed under the GNU GPL v3.0. You're free to use, modify, and distribute this code, but any project that uses it must also be open source and released under the same license. See the [LICENSE](./LICENSE) file for details.
