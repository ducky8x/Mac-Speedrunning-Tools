# MST

MST combines BetterNBB, WindowBackdrop, Better Piechart, MACrosshair, and Key Rebinder into one app.

Current version: 2.1.0
MST 2.1.0 adds automatic updates as well as options to rebind accents to keys. MST now checks for new releases on launch and shows an update banner in the sidebar when one is available. Clicking Update downloads and installs the new version automatically — MST restarts into the updated app without any manual steps.

MST 2.0.0 added Key Rebinder with visual keyboard and mouse remapping through Karabiner Elements, per-preset hotkeys, light mode, a new settings window, and a new upgraded Better Piechart.

## Requirements

- macOS 14 or newer
- Apple Swift toolchain (Optional: for source installs or local builds)
- Accessibility permission for global keybinds while another app is focused
- Screen Recording permission for screen-capture based overlays such as Better Piechart
- Karabiner-Elements for Key Rebinder

If macOS blocks the app the first time you open it, right-click the app and choose **Open**, or you can go to System Settings -> Privacy and Security, scroll all the way down, and open the app from there.

## Installation

### DMG release

1. Open `MST-<version>-macOS.dmg.zip`.
2. Drag `MST.app` to `Applications`.
3. Open the app from `Applications`.
4. Grant Accessibility or Screen Recording permissions if MST asks.

### Source installer ZIP

1. Unzip `MST-<version>-source-installer.zip`.
2. Double-click `compile_and_install.command`.
3. The installer builds the app from the included `README.md`, `Package.swift`, and `Sources/` folder, installs it into `Applications`, and opens it.
4. Move the file into the trash.

### Build from source

From the project folder:

```sh
swift build -c release
```

To create a local app bundle:

```sh
./scripts/build-app.sh
```

The app bundle is written to:

```text
dist/MST.app
```

## App Layout

The main app has a sidebar for:

- Overview
- BetterNBB
- WindowBackdrop
- Better Piechart
- MACrosshair
- Key Rebinder

Complex Mode shows the full settings for the selected tool. Simple Mode condenses the app into a grid of large toggle buttons plus a button to return to Complex Mode.

## Global Keybinds

Each tool can have its own keybind. Keybinds do not start the tool; they toggle the tool's internal overlay or visibility after that tool has been started.

- BetterNBB: show or hide the BetterNBB overlay
- WindowBackdrop: show or hide the backdrop
- Better Piechart: show or hide the piechart projector
- MACrosshair: show or hide the crosshair
- Key Rebinder: activate preset-specific hotkeys

Note: For the keybinds to work outside of MST, you must enable Accessibility permission for MST.

## Features

### BetterNBB

BetterNBB is a better overlay for NinjabrainBot.

- Start or stop the BetterNBB overlay
- Place and resize the overlay template
- Adjust prediction and eye throw row counts
- Choose which stronghold and eye throw columns are shown
- Hide 0% predictions
- Show NBB messages and movement hints
- Customize overlay background, opacity, border, corner radius, and shadow

### WindowBackdrop

WindowBackdrop draws a backdrop behind your Minecraft instance.

- Start or stop the backdrop
- Choose a solid backdrop color
- Use an image backdrop
- Choose image fit behavior
- Set empty-zone color for aspect-ratio preserving images
- Adjust opacity and blur
- Choose whether the backdrop covers the menu bar

### Better Piechart

Better Piechart creates a projector overlay that projects the Minecraft piechart round and displays the e-counter.

- Start or stop the piechart projector
- Show or hide the projector with a keybind
- Keep the projector always on top
- Show the titlebar when positioning the projector
- Select and clear the pie area
- Tune template height, crop size, and circle fit
- Preview raw capture and corrected pie output

### MACrosshair

MACrosshair draws a crosshair on the screen for MCSR Oneshot.

- Start or stop the crosshair
- Show or hide it with a keybind
- Pick from color presets
- Adjust line length, line thickness, center dot, dot size, and opacity
- Offset the crosshair position and reset it when needed

### Key Rebinder

Key Rebinder syncs Karabiner-Elements profiles and simple modifications from inside MST.

- Detect Karabiner connection status and open setup links when needed
- View and switch Karabiner profiles from MST
- Add, rename, enable, disable, and delete presets
- Assign a global hotkey to each preset
- Rebind keyboard keys and mouse buttons through a visual keyboard-and-mouse layout
- Add cursor-grabbed layer outputs that activate while the cursor is hidden
- Sync remaps back to Karabiner so the same rows appear in Karabiner-Elements
- Show warnings for key-to-mouse-button remaps that cannot key repeat

### Auto Update

MST can update itself automatically without leaving the app.

- Checks for a new release on every launch
- Shows an update banner in the sidebar when a newer version is available
- Downloading and installing happens in the background
- MST closes, replaces itself with the new version, and relaunches automatically

Auto-update was inspired by [harbs20](https://github.com/harbs20)'s contribution.
