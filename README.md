# MakeFilm

**English** | [日本語](README.ja.md)

A rough-cut video editor for macOS where **the film runs vertically**, like on a Moviola.
Instead of a horizontal timeline, you crank through your footage like 35mm film, mark it with a grease pencil and splice it together.
When the cut is done, hand it over to Final Cut Pro, Premiere Pro or DaVinci Resolve for finishing.

## Features

- **Vertical film strip** — the strip on the left has perforations (4 per frame), a seconds ruler and grease-pencil IN/OUT marks. Drag or scroll to crank it, with inertia. The film can run up (default) or down (Moviola style)
- **The viewer is a gate** — the picture sits on a continuous strip of film, with the previous and next frames above and below, perforations and edge numbers at the sides. While playing, the film advances a frame at a time like a projector's claw
- **Pedal** — speeds from −4× to 4×, true reverse playback and frame-accurate stepping (native AVFoundation playback)
- **Splicing and the trim bin** — mark IN/OUT and splice; each cut hangs in the bin at a length proportional to its duration. Drag to reorder, cut and lift at the gate, undo/redo
- **Projects** — `.makefilm` files store the source locations, IN/OUT marks, the reel and view settings. Open Recent, reopens the last project at launch, asks before discarding unsaved changes. Moved sources are found relative to the project file, or you can point to their new location
- **English and Japanese** — follows the macOS language (English on any non-Japanese system)
- **Export**
  - Files: H.264 (MP4), HEVC, Apple ProRes 422 / 4444, audio only (M4A), still image (PNG). Sizes: original / 4K / 1080p / 720p (downscale only)
  - Hand-off to editors: **FCPXML 1.10** (Final Cut Pro, DaVinci Resolve) and **Final Cut Pro 7 XML** (Premiere Pro, DaVinci Resolve). Clips reference the original files, so nothing is re-encoded. Camera timecode and NTSC rates such as 23.976 are preserved

## Requirements

- macOS 14 Sonoma or later (Apple Silicon or Intel)
- To build: Xcode (Swift 5.10 or later)

## Download

Get the latest app from [Releases](https://github.com/kamemamo/makefilm/releases). Unzip it and move `MakeFilm.app` to Applications.

The app is not notarized by Apple, so the first launch shows "cannot verify the developer". Try to open it once, then click **Open Anyway** in System Settings → Privacy & Security. Or from Terminal:

```bash
xattr -dr com.apple.quarantine /Applications/MakeFilm.app
```

## Build and run

```bash
cd mac
./scripts/build-app.sh               # builds build/MakeFilm.app
./scripts/build-app.sh --universal   # for distribution (Apple Silicon + Intel)
open build/MakeFilm.app
```

During development you can also use `cd mac && swift run MakeFilm ../samples/sample.mp4`; video files passed as arguments are loaded as sources. The version lives in `mac/Info.plist` (`CFBundleShortVersionString`) and is shown in the app's header.

## Controls

| Key | Action |
|---|---|
| Space | Play / stop |
| J / K / L | Reverse (faster each press) / stop / forward (faster each press) |
| ← → | Back / forward one frame (Shift: one second) |
| ↑ ↓ | Move the film up / down (follows the flow direction) |
| I / O | Mark IN / OUT |
| Return | Splice (add IN–OUT to the end of the reel) |
| C | Cut the film at the gate (reel) |
| X / Delete | Lift the cut at the gate (reel) |
| 1 / 2 | Source / reel view |
| ⌘N / ⌘O / ⌘S / ⇧⌘S | New project / open / save / save as |
| ⌘I / ⌘E / ⌘Z | Import clips / export / undo |

You can also drag or scroll on the film strip and on the viewer to crank the film.

## Finishing in Final Cut Pro and others

1. Export (⌘E) → under "Continue in an editor", choose Final Cut Pro (FCPXML) or Premiere Pro (XML)
2. Final Cut Pro: File → Import → XML… / Premiere Pro: File → Import… / DaVinci Resolve: File → Import → Timeline…

The XML points at your original source files — don't move them after exporting.

## Project layout

```
mac/                     macOS app (SwiftUI + AVFoundation, Swift Package)
  Sources/MakeFilm/      source code
  scripts/build-app.sh   assembles the .app
  scripts/make-icon.swift draws the app icon
  Resources/             icon (AppIcon.icns and the 1024px artwork)
  Localization/          UI text (en.lproj holds English; Japanese is the source text in code)
index.html               the first web prototype (open it in a browser)
samples/sample.mp4       test footage (color bars generated with ffmpeg)
```

## Localization

UI strings are written in Japanese in the code and looked up through `L("…")`; `mac/Localization/en.lproj/Localizable.strings` maps each one to English. To add a language, copy that file into a new `xx.lproj` folder, translate the right-hand side and add the language code to `CFBundleLocalizations` in `mac/Info.plist`.

## Specification

Screens, controls, data model, export formats and more are described in [docs/SPEC.md](docs/SPEC.md) (Japanese).

## License

[MIT](LICENSE)
