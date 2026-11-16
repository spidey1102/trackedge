# TrackEdge

Slide along the edges of your Mac's trackpad to change volume and brightness. TrackEdge is a tiny menu bar app (no Dock icon) for macOS that turns the physical edges of the trackpad into sliders.

It is written in a single Swift file and built with one shell script. It uses the private `MultitouchSupport` and `DisplayServices` frameworks, so macOS updates may break it.

## Gestures

| Gesture | Action |
| --- | --- |
| Slide up/down on the right edge | Volume |
| Slide up/down on the left edge | Brightness |
| Double-tap the top-right corner | Mute / unmute |
| Swipe left/right along the bottom edge | Previous / next track |
| Double-tap the bottom edge | Play / pause |
| Hold Shift + Option while sliding | Finer adjustments |

## Features

- macOS-style on-screen HUD (16 steps) while you slide
- Haptic feedback on each step
- Optional animated edge glow on the screen edge that follows your finger
- Cursor freeze: pointer movement and clicks are blocked while sliding, so the gesture can't hit anything underneath
- Only listens on trackpad surfaces (skips devices like the Magic Mouse), and restarts capture after sleep
- Open at Login toggle
- Auto-updates from GitHub Releases (checks on launch and daily)

## Requirements

- macOS 13.0 or later
- Xcode Command Line Tools: `xcode-select --install`
- Accessibility permission (for the cursor-freeze event tap)

## Build and run

```bash
git clone https://github.com/spidey1102/trackedge.git
cd trackedge
bash build.sh
```

`build.sh` compiles `main.swift` with `swiftc` into `TrackEdge.app`, signs it, and opens it. Set a version with `VERSION=0.2 bash build.sh`.

**Signing:** if a self-signed certificate named `TrackEdge Dev` exists in Keychain, the build uses it. Otherwise it falls back to ad-hoc signing, and macOS forgets the app's permissions on every rebuild. Create the certificate once via Keychain Access -> Certificate Assistant -> Create a Certificate.

**First run:** macOS will prompt for Accessibility access (System Settings -> Privacy & Security -> Accessibility). Without it, sliding still works, but the cursor freeze falls back to pinning the pointer and clicks are not blocked.

## Settings

Everything lives in the menu bar menu:

- **Enabled** - master on/off
- **Swap Sides** - brightness on the right edge instead
- **Haptic Feedback**, **Edge Glow**
- **Freeze Cursor & Block Clicks While Sliding**
- **Quick Mute** - double-tap the top-right corner
- **Media Strip** - bottom-edge swipes and double-tap play/pause
- **Reverse Media Swipe**
- **Active Area** - full edge, bottom 3/4, bottom half, or bottom quarter
- **Sensitivity** - Low / Medium / High
- **Edge Width** - Narrow / Default / Wide / Wider

## Updates

TrackEdge checks GitHub Releases on launch and once a day. Choose **Check for Updates...** in the menu to force a check. When a newer release with a `.zip` asset exists, it offers to download, install, and restart in place.

## How it works

- Raw trackpad touches come from the private `MultitouchSupport` framework (loaded with `dlopen`/`dlsym` at runtime).
- Brightness uses the private `DisplayServices` framework on the built-in display.
- Volume uses the CoreAudio HAL on the default output device.
- Media keys are posted as system-defined `CGEvent`s.
- The cursor freeze is a `CGEvent` tap that drops pointer-motion and click events while a slide is active, with a 4-second safety net so the pointer can never get stuck.

Because it relies on private frameworks, a macOS update may break it.
