# Dead Air 🐤

A canary in your menu bar that warns you when a microphone goes quiet while you're recording, before you lose another take to a flat wireless transmitter.

## How it works

When a wireless receiver like the RØDE Wireless GO II loses its transmitter (battery dead, out of range, muted), it keeps sending audio to the Mac, but every sample is exactly zero. A working mic never sends exact zeros: even in a quiet room there's a noise floor somewhere around −90 to −60 dBFS. Dead Air taps each selected input with a Core Audio IOProc, which is read-only and doesn't change the device or interfere with your recording app. It watches the peak level 10 times a second.

| Menu bar | Meaning |
|---|---|
| Outline canary (dimmed) | Disarmed |
| Solid canary | Armed, all mics live |
| Orange canary | A dropout happened that you haven't checked yet (open the menu to clear it) |
| Red belly-up canary, pulsing, `DEAD AIR 0:12` | A mic has been dead for more than 1.5s |

If dead air lasts longer than **Pop Up After** (5s by default), a red banner appears over everything, full-screen apps included. It doesn't use notifications, so Do Not Disturb doesn't block it. When audio comes back, the banner changes to "Back on air" and tells you when the dropout started, so you know where to re-record from. The menu also keeps a list of recent dropouts with timestamps.

A mic is considered dead if:

- **silent**: the peak stays at or below the threshold (default −100 dBFS, which catches exact digital silence),
- **no audio**: the device stops delivering buffers for 2s, or
- **disconnected**: the device disappears from the system (unplugged, Bluetooth dropped).

## Usage

1. `make install` builds the app, copies it to `/Applications` and launches it.
2. Click the canary, tick the microphone(s) to watch, and choose **Arm**. If you haven't ticked any, arming picks the current default input.
3. Allow microphone access the first time you arm.

While armed, the menu shows each mic's live peak level. If your receiver goes through an analog interface instead of USB, "off" may be the interface's noise floor rather than true zero. Check the level with the transmitter on and off, then choose a **Treat as Dead Air** level between the two.

`make probe` (or `swift run DeadAir --probe 10`) prints every input device and its level from the terminal.

## Building

Requires macOS 14+ and Xcode 16 / Swift 5.10+.

```
make test      # unit tests for the detection logic
make app       # build/Dead Air.app (universal, ad-hoc signed)
make run       # build and open
make install   # copy to /Applications and open
```

The build is ad-hoc signed by default, so macOS may ask for microphone permission again after each rebuild. To avoid that, sign with your own certificate: `CODESIGN_IDENTITY="Apple Development: …" make app`.

## Layout

- `Sources/DeadAirCore/SilenceTracker.swift`: pure live/dead decision logic (unit tested)
- `Sources/DeadAir/InputMonitor.swift`: per-device Core Audio IOProc and real-time peak meter
- `Sources/DeadAir/AudioSystem.swift`: device enumeration and hot-plug listener
- `Sources/DeadAir/AppController.swift`: menu bar item, menu, arming, polling
- `Sources/DeadAir/AlertPanel.swift`: the floating "dead air" banner
- `Sources/DeadAir/StatusIcon.swift`: canary icons
