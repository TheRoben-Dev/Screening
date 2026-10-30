# Screening

> [!IMPORTANT]
> **This app was made with AI.** Its code, sounds, icon and this README were written by Claude, Anthropic's AI model, working from one person's direction and feedback. A person chose what to build and judged the results, but did not write the code by hand. Read the [testing notes](#testing-status) before relying on it.

Screening is a menu bar screenshot app for macOS, built to feel like it came with the Mac. It captures a selection, a window or the entire screen, saves the result to a folder you choose and copies it to the clipboard, then lets you mark it up in a Liquid Glass editor.

## Features

### Capture

- **Selection, window or entire screen.** The screen freezes while you choose, so nothing changes under you.
- **Saved and copied automatically.** Every normal capture goes to your folder as a PNG and onto the clipboard.
- **Clipboard-only shortcut.** One shortcut only copies: no file, no editor, no preview.
- **Capture Text.** Select an area and its text is copied. Recognition runs on your Mac using Apple's Vision framework.
- **Self-timer.** A 5 second countdown from the menu bar, for capturing menus and hover states.
- **Recent screenshots.** Your last five, one click away in the menu.

### Look and feel

- **Selection box.** Rounded corners, a soft luminous edge and a moving shimmer, in the spirit of lifting a subject in Photos.
- **Shadow on every screenshot.** A macOS-style drop shadow on a transparent background. Window captures keep their rounded corners, and the window itself stays at full resolution.
- **Capture animation.** The screen ripples like a liquid, starting at your pointer. A GPU shader bends the real pixels, so nothing is drawn on top.
- **Capture sounds.** Tink, Liquid, Scanner, Instant Camera or none. The three custom sounds are synthesized by the scripts in this repo.

### Editor

| Key | Tool |
| --- | --- |
| V | Select, move and delete annotations |
| C | Crop |
| P | Pen |
| A | Arrow |
| R | Rectangle |
| T | Text |
| N | Numbered step |
| H | Highlight |
| B | Blur, which pixelates first so the text underneath can't be recovered |
| S | Turn the shadow on or off |

| Shortcut | Action |
| --- | --- |
| ⌘Z / ⇧⌘Z | Undo / redo |
| ⌘C | Copy the edited image |
| ⌘P | Pin to screen |
| ⌘S or ⌘↩ | Save and close |
| ↩ | Apply the crop |
| Delete | Delete the selected annotation |

The editor's background is clear Liquid Glass showing a blur of what's behind the window. Its toolbar collapses in stages as the window narrows, so nothing clips.

### After a capture

Settings lets you choose what happens next:

- **Open Editor**, the default.
- **Show Thumbnail**, a floating preview in the corner. Click it to edit, drag it into another app, or pin it.
- **Do Nothing**.

**Pin to Screen** keeps a screenshot floating above your other windows for reference. Drag it to move it, and right-click to copy or unpin.

## Default shortcuts

| Shortcut | Action |
| --- | --- |
| ⌃⇧1 | Capture entire screen |
| ⌃⇧2 | Capture selection |
| ⌃⇧3 | Capture window |
| ⌃⇧4 | Copy to clipboard only |
| ⌃⇧5 | Capture text |

All of them can be changed in Settings. While selecting, press Esc or right-click to cancel.

## Requirements

- macOS 26 or later, because the interface uses Liquid Glass APIs
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and install

```bash
scripts/build.sh
```

This generates the Xcode project, builds a Release version and installs it to `/Applications/Screening.app`, replacing any existing copy.

To work on it in Xcode:

```bash
xcodegen generate
open Screening.xcodeproj
```

To run the tests:

```bash
xcodegen generate
xcodebuild -project Screening.xcodeproj -scheme Screening test
```

If `xcode-select` points at the Command Line Tools, put `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` in front of the `xcodebuild` command. `scripts/build.sh` already does this.

### If your project folder is in iCloud Drive

iCloud adds file attributes that make `codesign` fail with "resource fork, Finder information, or similar detritus not allowed". `scripts/build.sh` avoids this by keeping build products in `~/Library/Caches/Screening`. Use `-derivedDataPath` outside iCloud for your own `xcodebuild` commands too.

## Permissions

Screening needs **Screen Recording** access. Your first capture brings up the system prompt. Turn Screening on in System Settings under Privacy & Security, then quit and reopen the app.

The default build is signed ad hoc, so macOS treats every rebuild as a new app and the old permission stops applying. If Screening doesn't detect its access after a rebuild, quit it and reset the entry:

```bash
tccutil reset ScreenCapture com.theroben.Screening
```

Then capture again and grant access. Signing with a stable certificate stops this from recurring. Set `CODE_SIGN_IDENTITY` and `DEVELOPMENT_TEAM` in `project.yml`.

Global shortcuts use Carbon hotkeys, so they don't need Accessibility access. The app is not sandboxed, which lets it save to any folder you choose. Screenshots stay on your Mac: the app has no networking code.

## How it works

| Area | Approach |
| --- | --- |
| App | SwiftUI `MenuBarExtra`, with AppKit for windows and panels. It becomes a regular app with a Dock icon only while a window is open. |
| Capture | ScreenCaptureKit. The system's window shadow option squeezes the window into the same output size, so windows are captured without it and `ScreenshotShadow` adds the shadow afterward. |
| Window picking | `CGWindowList`, because it reports windows front to back and ScreenCaptureKit doesn't promise an order. |
| Editor | One Core Graphics drawing path serves both the canvas and the export, so what you see is what gets saved. Annotations are stored in image pixels. |
| Capture animation | A Metal fragment shader treats the screen as a liquid height field. Bending, shading and highlights all come from its slope. The shader compiles from source at launch, so building doesn't need Xcode's separate Metal Toolchain. |
| Sounds | Original and synthesized with the Python standard library. No samples are used. |

```
Screening/
  App/        Menu bar app, capture flow, sounds, clipboard and file output, floating panels
  Capture/    ScreenCaptureKit, selection overlay, shadow, capture animation, text recognition
  Editor/     Model, canvas, annotations and export, toolbar, window
  Settings/   Preferences, global hotkeys, settings window
  Resources/  Generated sounds
ScreeningTests/  Unit tests that also drive the real editor and overlay views
scripts/         Build script, plus generators for the sounds and icon
project.yml      XcodeGen project definition
```

To change a sound, edit its script and run it, for example `python3 scripts/make_liquid_sound.py`, then rebuild.

### Launch arguments

These are useful for development and scripting:

```bash
/Applications/Screening.app/Contents/MacOS/Screening --trigger display
/Applications/Screening.app/Contents/MacOS/Screening --edit image.png --shadow
/Applications/Screening.app/Contents/MacOS/Screening --settings
```

`--trigger` accepts `area`, `window`, `display`, `clipboardOnly` or `text`.

## Testing status

This project has only been built and run on one Mac, on macOS 27 with Xcode 27.

**Checked:**

- The automated test suite passes. It covers annotation rendering and export, crop, undo, blur, the shadow, text recognition, shader compilation and toolbar sizing, and it drives the editor and overlay with simulated mouse events.
- Real full-screen captures were run, confirming the saved file, the clipboard contents and the editor opening. The clipboard-only action was confirmed to create no file or window.
- The animation, selection box, toolbar layouts and thumbnail were inspected as still frames from test windows.

**Not fully checked by the AI that built it,** because it couldn't press keys or click on the machine:

- Physical hotkeys and real mouse selection on the overlay
- Clicking to pick a window, end to end
- Dragging the thumbnail, moving pinned images, and opening the toolbar's menus and popover
- The animations in motion, and how the sounds actually sound
- Multiple displays and mixed display scales

The person directing the project used the app and gave feedback throughout, but that isn't a formal test pass. Please open an issue if something misbehaves.

## Known limitations

- Region captures save as sharp rectangles, while the selection box has rounded corners.
- Scrolling capture and screen recording aren't included.
- Builds are signed ad hoc and not notarized, so there's no ready-to-download app yet. You build it yourself.
- Files reopened from Recent Screenshots already have any shadow baked in, so the editor can't remove it from them.

## License

Screening is released under the [MIT License](LICENSE). You can use, change, fork, sell or redistribute it however you like. The one condition is that copies keep the copyright and license notice.

Screening isn't affiliated with or endorsed by Apple. Apple, macOS, AirDrop and Liquid Glass are trademarks of Apple Inc.
