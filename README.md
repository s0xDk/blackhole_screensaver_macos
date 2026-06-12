# BlackHoleSaver — a black hole screensaver for macOS

A macOS screensaver that screenshots your desktop the moment it starts, then swallows it: your windows bend, magnify and mirror around a geodesic-traced Schwarzschild black hole with a relativistic accretion disk.

![BlackHoleSaver preview](preview.jpg)

After Eric Bruneton's [Real-time High-Quality Rendering of Non-Rotating Black Holes](https://ebruneton.github.io/black_hole_shader/), via the single-pass adaptation from [blackhole_ghostty](https://github.com/s0xDk/blackhole_ghostty). Each pixel's null geodesic is integrated numerically in one Metal fragment pass — everything the camera sees falls out of that integration rather than being painted on:

- **the shadow** — rays with impact parameter under b₍crit₎ = (3√3/2) rₛ spiral into the horizon (your windows really are gone, not faded)
- **gravitational lensing** — escaped rays are projected back onto the desktop "sky" plane: the screenshot bends, magnifies, and mirrors inside the Einstein ring
- **photon ring** — rays winding near the r = 1.5 rₛ photon sphere
- **accretion disk** — a thin Keplerian disk the ray may cross several times (the far side arcs over and under the shadow); blackbody color from a Shakura–Sunyaev temperature profile, shifted and beamed by the relativistic Doppler factor
- **starfield** — a lensed sky, shown when the desktop can't be captured

## Requirements

- macOS 14 (Sonoma) or later
- Any Mac with Metal (Apple Silicon recommended)

## Install

1. Download `BlackHoleSaver.saver.zip` from [Releases](https://github.com/s0xDk/blackhole_screensaver_macos/releases) and unzip it.
2. Double-click `BlackHoleSaver.saver` — it installs to `~/Library/Screen Savers/`.
3. Select **BlackHoleSaver** in **System Settings → Screen Saver**.
4. Grant the Screen Recording permission (next section) — without it the saver shows a lensed starfield instead of your desktop.

Releases are Developer ID signed and notarized. If macOS refuses to open a copy that traveled through some other channel, clear the quarantine flag: `xattr -dr com.apple.quarantine BlackHoleSaver.saver`.

<details>
<summary>Build from source instead</summary>

```sh
brew install xcodegen
git clone https://github.com/s0xDk/blackhole_screensaver_macos.git
cd blackhole_screensaver_macos
xcodegen generate
xcodebuild -project BlackHoleSaver.xcodeproj -scheme BlackHoleSaver -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/BlackHoleSaver-*/Build/Products/Release/BlackHoleSaver.saver ~/Library/Screen\ Savers/
killall legacyScreenSaver 2>/dev/null; true
```

</details>

## Screen Recording permission

Capturing the desktop requires the **Screen Recording** permission, and third-party savers run inside Apple's host process `legacyScreenSaver` — so the permission must be granted to *that*, not to the saver bundle. The "+" picker in Privacy & Security won't help: it only accepts regular `.app` bundles, and `legacyScreenSaver.appex` is an app extension inside a system framework. Drag-and-drop is the way:

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording**.
2. In **Finder**, choose **Go → Go to Folder…** (<kbd>⇧⌘G</kbd>) and paste:

       /System/Library/Frameworks/ScreenSaver.framework/PlugIns/

3. Drag **`legacyScreenSaver.appex`** from that Finder window and drop it onto the app list in the Screen Recording settings, then make sure its toggle is on.
4. Run `killall legacyScreenSaver` in Terminal (or log out and back in) so the host relaunches with the permission.

Run the screensaver — your desktop falls into the hole.

## Settings & presets

System Settings → Screen Saver → BlackHoleSaver → **Options…**:

- **Preset** — Inferno (default), Gargantua, M87* Donut, Face-on Ember, Quasar, Blazar, Pure Lens (no disk, pure geometry + starfield), Zen.
- **Hole size** — apparent shadow radius; the visible footprint spans ~1.5% of the screen at the minimum to ~12% at the max.
- **Drift speed** — how fast the hole wanders (0 = static centered).
- **Warp reach** — how far out the desktop visibly bends, in hole radii; the top of the range warps essentially the whole screen.
- **Quality** — render scale. *Auto* (default) caps the render at 1800 rows, which is indistinguishable in motion and keeps 5K/6K displays fast; Full / 75% / 50% are manual overrides.

## Credits

- [Eric Bruneton's black hole shader](https://ebruneton.github.io/black_hole_shader/) — the rendering approach.
- [blackhole_ghostty](https://github.com/s0xDk/blackhole_ghostty) — the single-pass numeric adaptation and disk model this shader is ported from.
