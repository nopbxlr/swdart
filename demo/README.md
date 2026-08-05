# swdart demo

A small cross-platform flashing & debugging utility built entirely on
[`package:swdart`](../). One screen: connect a probe, inspect the target, flash
a `.bin`/`.hex`, dump & save, check/unlock read protection, and debug
(halt/run/step, registers, memory viewer).

## Run

```sh
flutter pub get

flutter run -d chrome     # web (WebUSB — Chrome/Edge)
flutter run -d windows    # native desktop (libusb; DLL bundled — see below)
flutter run -d macos      # macOS (brew install libusb)
flutter run -d linux      # Linux (sudo apt install libusb-1.0-0)
```

## Notes

- **Web** needs Chrome/Edge (WebUSB) over HTTPS or localhost. First connect must
  come from a click; on Windows the ST-Link must use the WinUSB driver (Zadig /
  ST driver).
- **Windows** ships `windows/libusb-1.0.dll` (bundled next to the exe for debug
  and release). macOS/Linux use system/Homebrew libusb.
- Everything hardware-facing lives in `swdart` — this app is just UI, and a
  reference for how to drive the library.
