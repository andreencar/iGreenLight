# iGreenLight

[![CI](https://github.com/andreencar/iGreenLight/actions/workflows/ci.yml/badge.svg)](https://github.com/andreencar/iGreenLight/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
![Platforms: macOS 15+, iOS 18+](https://img.shields.io/badge/platforms-macOS%2015%2B%20%7C%20iOS%2018%2B-lightgrey.svg)

A native macOS and iOS app for Xbox Remote Play (xHome) and Xbox Cloud Gaming (xCloud).
It is written in Swift and SwiftUI, uses Google's libwebrtc for transport, renders with Metal and
MetalFX Spatial upscaling, and takes input through the GameController framework. It has no Electron and no web view.

![The console list, shown with demo data](.github/images/consoles.png)

**iPhone and iPad:** an unsigned `.ipa` is on the [Releases](https://github.com/andreencar/iGreenLight/releases) page, to
install with your own Apple ID (see [Installing on iPhone or iPad](#installing-on-iphone-or-ipad)).
**Mac:** build it from this source (see [Build](#build)).

iGreenLight is a port of **[Greenlight](https://github.com/unknownskl/greenlight)** by
UnknownSKL (Jim Kroon), MIT licensed. The protocol knowledge (auth flow, gssv session API, data channel
messages, input report format) comes from Greenlight and its auth library
[xal-node](https://github.com/unknownskl/xal-node). iGreenLight itself is MIT licensed ([`LICENSE`](LICENSE)). Greenlight's and WebRTC's
licenses are in [`Licenses/`](Licenses); they ship inside the app and are shown under Settings → About. Ideas from
[Better xCloud](https://github.com/redphx/better-xcloud) were also used: the quality profiles chosen by the device-info OS name, and the console address used as an ICE candidate.

Not affiliated with, endorsed by or supported by Microsoft or Xbox. Xbox is a trademark of Microsoft.

**Use at your own risk.** iGreenLight is an unofficial client. Like Greenlight, it signs in with the client ID of Microsoft's
own Xbox app and talks to the streaming service the way the Xbox web client does. Microsoft may block this at any time, and
using an unofficial client may be against the terms of your account.

## Installing on iPhone or iPad

The release `.ipa` is **unsigned**, so nothing in it is tied to anyone's Apple account. It will not install by
itself: a sideloading tool signs it with *your* Apple ID and puts it on your device.

1. Download `iGreenLight-<version>-unsigned.ipa` from [Releases](https://github.com/andreencar/iGreenLight/releases).
   `SHA256SUMS.txt` next to it lets you check the download.
2. Install it with a sideloading tool such as [AltStore](https://altstore.io), [SideStore](https://sidestore.io) or
   [Sideloadly](https://sideloadly.io), signing in with your Apple ID when it asks.
3. On the device, trust your developer certificate if iOS asks (Settings → General → VPN & Device Management).

With a free Apple ID an app installed this way stops opening after 7 days until the tool refreshes it; a paid
developer account lasts a year. These tools are independent projects, not part of iGreenLight.

Or build it yourself: see [iPhone / iPad](#iphone--ipad) under Build. `scripts/make-ipa.sh` produces the same
unsigned `.ipa` locally.

## Requirements

* macOS 15+, Apple silicon; or iOS 18+
* Xcode 26 or later (the code uses APIs from the macOS 26 / iOS 26 SDKs; built and tested with Xcode 27.2)
* [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`), only if you change `project.yml`: the generated project is in the repository

## Build

```bash
xcodebuild -project iGreenLight.xcodeproj -scheme iGreenLight -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/iGreenLight.app
```

Unit tests (Swift Testing, in `Tests/iGreenLightTests`, hosted in the Mac app; they need no account or network):

```sh
xcodebuild test -project iGreenLight.xcodeproj -scheme iGreenLight -derivedDataPath build -destination 'platform=macOS,arch=arm64'
```

### iPhone / iPad

The `iGreenLight-iOS` target builds the same sources for iOS 18+ (platform differences are behind `#if os(iOS)`).

```bash
xcodebuild -project iGreenLight.xcodeproj -scheme iGreenLight-iOS -destination 'id=<device UDID>' -derivedDataPath build -allowProvisioningUpdates build
xcrun devicectl device install app --device <device UDID> build/Build/Products/Debug-iphoneos/iGreenLight.app
```

The app icons are in `Platforms/*/Assets.xcassets`. `scripts/make-mac-icon.swift` and `scripts/make-ios-icon.swift` render them from
a 1024 px artwork file, which is not in the repository.

### Controller navigation

Both apps use the same console-style interface (`Sources/UI/XboxTheme.swift`) and can be driven entirely with a controller
(`Sources/Input/PadNavigator.swift`): D-pad or left stick to move, A to select, B to go back, LB / RB to switch tabs,
left / right to change a setting. The arrow keys, Return and Escape do the same. During a stream the controller belongs to
the game; clicking both sticks together (L3 + R3) opens the stream menu. The Microsoft sign-in page is a web page and still
needs touch or a mouse. `--ui-demo` (debug builds) shows the signed-in screens with made-up consoles and games.

### iPhone and iPad differences

What differs from the Mac app:

* The stream is a full-screen cover, landscape only, and keeps the screen awake. Its buttons are a row at the top; with a
  controller connected they become a column on the right-hand edge, where iPhone Duo places an app's controls, in the
  black bar beside the picture when there is one. In a window taller than wide (iPhone Duo's inner display, which doesn't
  honour the landscape request) the on-screen gamepad keeps to a band along the bottom and the picture moves to the top.
* On-screen gamepad (`Sources/Input/TouchGamepad.swift`) while no controller is connected; rumble goes to the phone's Taptic Engine.

  ![The on-screen gamepad](.github/images/touch-gamepad.png)

  Settings → Input → "Try on-screen controls" shows it without a stream (`--touch-test` opens it at launch and logs every change).
* Hardware keyboards go through `GCKeyboard`, with the same mapping as on the Mac.
* Sign-in opens the Microsoft page in an in-app Safari sheet.
* The log and diagnostics are in the app's Documents folder (Files → On My iPhone → iGreenLight).
* Default quality is 1080p HQ. Audio plays through its own 48 kHz stereo output unit (`Sources/Streaming/GameAudioDevice.swift`), not libwebrtc's call-oriented iOS device; nothing is captured from the microphone.
* The Simulator SDK has no MetalFX and no VideoToolbox ML scaler, so both are compiled out there; devices have them.

Signing is set in `Config/Signing.xcconfig`, which signs ad hoc by default: enough to build and run the Mac app.
For your own team (needed to run on an iPhone or iPad), copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig`
and put your team ID there; that file is not in git.

## Features

* Microsoft sign-in with the device-code flow (same client id as Greenlight). The tokens are stored in the Keychain.
* Console list from `/v6/servers/home`, with the SmartGlass device list as a fallback.
* Remote Play: session start, `/connect` with the console transfer token, SDP/ICE over HTTP, Teredo
  candidate decoding, and the console's `serverDetails` address added as an extra ICE candidate. Keepalive runs every 30 s.
* Data channels `control`, `input`, `message` and `chat`: handshake, `dimensionschanged`, transactions
  (server disconnect, message dialogs).
* Rendering: CVPixelBuffer (NV12) is converted from YUV to RGB in Metal, upscaled with MetalFX Spatial, and drawn as fit, zoom or stretch.
* Input: GameController pads (up to 4) with rumble through CoreHaptics. The keyboard can act as a virtual gamepad.
  Mouse-and-keyboard mode (Settings → Input, or the stream menu; experimental) sends the keyboard and mouse to the game as
  themselves (`Sources/Input/MouseInput.swift`): on the Mac, click the picture to capture the pointer and press ⌘ to release it.
  View+Menu together act as the Xbox button.
* Audio is played by libwebrtc's CoreAudio device module on the Mac (see the iPhone section for iOS).
* Mac on Wi-Fi: AWDL (AirDrop, AirPlay, Handoff) is kept off while a stream runs, because it makes the radio leave the
  network's channel at regular intervals, which shows as latency spikes. That needs root, so a small helper does it
  (`Platforms/macOS/AWDLHelper/main.c`): turn it on once in Settings → Network and approve iGreenLight under Allow in the
  Background in System Settings. A build that can't register it copies a `sudo sh …/install-awdl-helper.sh` command for
  Terminal instead. Without the helper nothing changes. iOS has no way to turn AWDL off.
* Cloud Gaming: the Game Pass library (`/v2/titles` plus catalog.gamepass.com box art), queue / wait times.
* Freeze recovery: when no frame has arrived for about 150 ms (at least five stream frames) while video data still
  comes in, the app asks the console for a keyframe, at most once a second.
* Settings: quality (720p / 720p HQ / 1080p / 1080p HQ / 1440p; on Remote Play the console is asked for that resolution, on cloud
  gaming it picks the server profile through the device-info OS `android` / `windows` / `tizen`; 720p HQ is the tier the
  VideoToolbox ML upscaler can take to 1080p, and on cloud gaming it uses the 720p profile), an experimental 16:10
  request, scaling mode, upscaler (off, MetalFX Spatial, or VideoToolbox ML + MetalFX), debanding, sharpening, ambient bars in the
  letterbox, HDR highlight expansion, region override, and a stats overlay.
* Picture settings that are on by default: "Draw frames as they arrive" (a frame is drawn when it is decoded instead of
  at the display's next refresh), "Sharper colour edges" (colour, which the video carries at half resolution, is rebuilt
  along the brightness edges), "Adaptive sharpening" (while the stream is heavily compressed the sharpening is eased
  off and the debanding strengthened, judged from the quantiser the decoder reports; a decoder that reports none leaves
  the sharpening as set) and "Protect frame rate" (the upscaler steps down while the device is hot or the GPU needs more than about
  60% of a frame, and back up after a longer healthy period). The stats overlay shows when either of the last two is
  holding something back.
* Settings → Experimental: Transport, all off by default and **untested against a console**: offer video retransmission
  (RTX), low-latency playout (no jitter-buffer delay), faster audio catch-up, and reporting each frame's timing to the
  server as the official web client does. They apply from the next stream and are recorded with each diagnostics run.

The log is written to `~/Library/Containers/app.igreenlight.iGreenLight/Data/Library/Application Support/iGreenLight/iGreenLight.log`.
You can also open it from Settings → Log. It holds no tokens, but it does hold your console's name and ID, session IDs
and the IP addresses of both ends: look it over before pasting it into a bug report.

## Diagnostics

Settings → Experimental: Diagnostics records each stream to `diagnostics/<timestamp>/` next to the log.
It captures the gssv HTTP calls (tokens stripped), the SDP offer and answer with a parsed summary, data-channel messages, getStats
every second, decoded-frame pixel formats and colour/HDR attachments, and SPS/SEI parsed from the bitstream. The same section has
switches to compare codec (H.264 profiles, HEVC Main/Main 10 via a VideoToolbox decoder, VP9, AV1), client profile, bitrate ceiling
and reported display size. `--diagnostics-selftest` (debug builds) checks the capture offline. The files a capture contains are listed at the top of
`Sources/Diagnostics/DiagnosticsRecorder.swift`.

## Contributing

Bug reports and pull requests are welcome; start with [CONTRIBUTING.md](CONTRIBUTING.md). Everyone taking part is
expected to follow the [code of conduct](CODE_OF_CONDUCT.md). Please report security problems privately, as
described in [SECURITY.md](SECURITY.md).

## Licence

iGreenLight is released under the [MIT licence](LICENSE). It builds on [Greenlight](https://github.com/unknownskl/greenlight)
(MIT) and links [WebRTC](https://webrtc.org) (BSD 3-clause); their licence texts, and those of the libraries inside the WebRTC binary, are in [`Licenses/`](Licenses).
