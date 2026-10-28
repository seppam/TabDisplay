# TabDisplay

**English** · [Bahasa Indonesia](README.id.md)

Use an Android tablet as an extra display for your Mac, like Sidecar but for Android. No app is needed on the tablet. It only needs Chrome.

- Extends your desktop (it doesn't just mirror it) at 2560×1600 HiDPI, 60 fps, hardware H.264
- Touch, S Pen and keyboard/mouse input go back to the Mac
- Portrait and landscape follow the tablet's rotation
- Works over a USB cable, or over Wi-Fi with wireless debugging
- Lives in the menu bar

Tested on a Galaxy Tab S8 (Android 16, Chrome 156) with macOS 27 on Apple Silicon. Any Android device with a recent Chrome should work.

## How it works

```
Mac (TabDisplay.app)                                           Android tablet (Chrome)
virtual display → ScreenCaptureKit → VideoToolbox H.264 → WebSocket ═adb═▶ WebCodecs → <canvas>
      ▲                                                                        │
      └──────────────── CGEvent mouse/scroll ◀──── touch / S Pen ──────────────┘
```

1. **Virtual display.** macOS's private `CGVirtualDisplay` API creates a monitor that macOS treats as real. This is how BetterDisplay and similar tools work.
2. **Capture and encode.** ScreenCaptureKit records that display, and VideoToolbox encodes it with the hardware H.264 encoder in low-latency mode.
3. **Transport.** A small server on `127.0.0.1` serves the viewer page (port 8080) and streams frames over a WebSocket (port 8081). `adb reverse` maps those ports onto the tablet's own `localhost`.
4. **Decode.** Chrome's WebCodecs decodes the H.264 in hardware and draws it on a canvas. WebCodecs only works on secure origins, and `localhost` counts as one. That is why the tablet opens `http://localhost:8080` instead of the Mac's IP address.
5. **Input.** Touches go back over the same WebSocket and are turned into mouse events on the virtual display.

## Requirements

- macOS 14 Sonoma or newer
- An Android tablet or phone with Chrome
- A USB data cable, or the Mac and tablet on the same Wi-Fi network
- `adb` from Homebrew:
  ```bash
  brew install android-platform-tools
  ```

## Install

### Option A: download the app

1. Download `TabDisplay-x.y.z.dmg` from [Releases](https://github.com/seppam/TabDisplay/releases).
2. Open it and drag **TabDisplay** into **Applications**.
3. Open TabDisplay. macOS will block it the first time (see the next section).

#### "TabDisplay can't be opened" (Gatekeeper)

TabDisplay is free and open source, and it isn't signed with a paid Apple Developer ID, so macOS can't verify the developer. This is normal for small open-source Mac apps. You can allow it in either of two ways:

- **System Settings:** try to open the app once, then go to **System Settings → Privacy & Security**. Scroll down to the message about TabDisplay and click **Open Anyway**, then confirm.
- **Terminal:** remove the download quarantine flag:
  ```bash
  xattr -dr com.apple.quarantine /Applications/TabDisplay.app
  ```

If you'd rather not trust a downloaded binary, build it yourself (Option B). The whole app is a few hundred lines of Swift.

### Option B: build from source

You need Xcode or the Xcode Command Line Tools.

```bash
git clone https://github.com/seppam/TabDisplay.git
cd TabDisplay
swift run -c release
```

This runs the menu bar app straight from Terminal. In this mode macOS asks for permissions for **Terminal**, not for TabDisplay.

To build your own `.app` and `.dmg` into `dist/`:

```bash
packaging/build-app.sh 1.0.0
```

## Setup

### 1. On the tablet: allow USB debugging (one time)

1. **Settings → About tablet → Software information**, then tap **Build number** 7 times to turn on Developer options.
2. **Settings → Developer options**, then turn on **USB debugging**.
3. Connect the tablet to the Mac with a USB cable. If the tablet asks what the USB connection is for, choose **Transferring files**.
4. When **Allow USB debugging?** appears, tick *Always allow from this computer* and tap **Allow**.

If the prompt doesn't appear, turn USB debugging off and on again and reconnect the cable. Plug straight into the Mac rather than through a hub, and try a different cable. Some cables only charge.

### 2. On the Mac: grant permissions (one time)

When TabDisplay first starts, macOS asks for two permissions in **System Settings → Privacy & Security**:

| Permission | Why | Without it |
|---|---|---|
| **Screen Recording** (may be called *Screen & System Audio Recording*) | To capture the virtual display | Nothing is streamed. After granting it, **quit and reopen** TabDisplay. |
| **Accessibility** | To turn touches into mouse clicks | You see the screen, but touches do nothing |

> **After updating TabDisplay**, macOS may treat the new version as a different app, because it is not Developer ID signed. If touch or video stops working after an update, remove TabDisplay from both lists with the **−** button, then add it again.

### 3. Connect

1. Open TabDisplay. An iPad-shaped icon appears in the menu bar, and the menu shows your tablet's name.
2. On the tablet, open Chrome and go to **`http://localhost:8080`**.
3. **Tap once** to go fullscreen. That first tap is not sent to the Mac.
4. On the Mac, open **TabDisplay menu → Arrange Displays…** and drag the display to match where the tablet sits on your desk.

## Gestures

| On the tablet | On the Mac |
|---|---|
| Tap | Click |
| Touch and drag | Click and drag |
| Touch and hold (½ s) | Right click |
| Two-finger drag | Scroll |
| Tap the bottom edge, or a three-finger tap | Show the Dock (when Dock auto-hide is on) |
| S Pen hover | Move the pointer |
| S Pen with the side button pressed | Right click |
| Rotate the tablet | Display switches between portrait and landscape |

A keyboard or mouse attached to the Mac works on the tablet's display like on any other monitor.

## Wireless (Wi-Fi)

`adb reverse` also works over wireless debugging, so the tablet still opens `localhost`.

1. Put the Mac and the tablet on the same Wi-Fi network.
2. On the tablet, go to **Developer options → Wireless debugging**, turn it on, and tap **Pair device with pairing code**.
3. On the Mac, pair using the IP address, port and code shown on the tablet:
   ```bash
   adb pair 192.168.1.23:37000
   ```
4. Connect using the IP address and port shown on the main **Wireless debugging** screen. This port is different from the pairing port:
   ```bash
   adb connect 192.168.1.23:41000
   ```
5. Unplug the USB cable. TabDisplay picks up the wireless connection within a few seconds.

Wi-Fi adds latency and depends on your network. 5 GHz Wi-Fi close to the router works best. The pairing is remembered, but the connect port changes whenever wireless debugging restarts, so repeat step 4 when that happens.

## Troubleshooting

| Problem | Fix |
|---|---|
| Menu says **adb not found** | `brew install android-platform-tools`, then reopen TabDisplay |
| Menu says **No tablet** | Check that USB debugging is allowed on the tablet. Running `adb devices` should list the tablet as `device`, not `unauthorized`. |
| Page says **WebCodecs not available** | You opened the Mac's IP address. Use `http://localhost:8080`. |
| Page loads but stays black | Grant **Screen Recording**, then quit and reopen TabDisplay |
| Video works, touch doesn't | Grant **Accessibility** (or remove and re-add it after an update) |
| **Port 8080 is unavailable** | Another TabDisplay, or another app using that port, is running. Quit it. |
| Tablet screen turns off | The page keeps the screen awake while it is visible. As a fallback, turn on **Developer options → Stay awake**. |
| Stuttering over Wi-Fi | Move closer to the router, use 5 GHz, or use USB |

## Limitations

- **Private API.** `CGVirtualDisplay` is undocumented and a macOS update could break it.
- **Mouse only, no multitouch.** macOS has no touchscreen support, so touches become mouse and scroll events. Pinch-zoom, rotation and pen pressure aren't passed through.
- **Chrome only.** Other browsers may lack WebCodecs H.264 decoding.
- **One resolution**, 1280×800 points (2560×1600 pixels).

## Roadmap

- Pinch to zoom and other trackpad gestures
- Resolution and bitrate settings in the menu
- Launch at login

## Security

The server listens on `127.0.0.1` only, so other devices on your network can't see your screen or send input. Only devices connected through your own `adb` can reach it.

## License

[MIT](LICENSE). TabDisplay is not affiliated with Apple, Samsung or Google.
