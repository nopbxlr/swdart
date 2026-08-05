# swdart

Program and **debug** ARM Cortex-M microcontrollers over an **ST-Link**, in pure
Dart — **WebUSB** in the browser, **libusb** on desktop. No native plugin, no
bundled OpenOCD, no child processes.

```dart
import 'package:swdart/swdart.dart';

final probe = Probe()..onLog(print);
final target = await probe.connect(ConnectMode.underReset);
print('connected to ${target.name}');

await probe.program(0x08000000, firmwareBytes); // reset-halt + erase + write + verify
await probe.resetRun();
await probe.disconnect();
```

## What you get

- **Debugging** — halt / resume / single-step, read & write core registers,
  read & write arbitrary memory, reset-halt / reset-run.
- **Programming** — read (dump), erase, write, verify flash; a one-call
  high-level `program()`; read-protection get/set including the mass-erase
  *unbrick* path.
- **One codebase, two transports** — the USB layer is chosen by conditional
  import: WebUSB (`dart:js_interop`) on web, libusb-1.0 (`dart:ffi`) on desktop.
  Runs in Flutter (web + desktop) and in plain Dart CLIs.

## Support matrix

| | |
|---|---|
| Probes | ST-Link/V2, V2-1, V3 (and V2 clones) |
| Targets | STM32F103 (FPEC), Artery **AT32F415** (FMC) — flash + RDP/FAP |
| Platforms | Web (Chrome/Edge, WebUSB), Windows, macOS, Linux (libusb) |

The transport, target-detection and flash-driver layers are abstractions
(`UsbTransport`, `detectTarget`, `FlashDriver`), so more probes/chips can be
added without touching the rest.

## Install

```yaml
dependencies:
  swdart: ^0.1.0
```

## Platform setup

**Web** — Chrome or Edge (WebUSB isn't in Firefox/Safari), served over HTTPS or
`localhost`. On Windows the ST-Link must use the **WinUSB** driver (ST's
STSW-LINK009, or [Zadig](https://zadig.akeo.ie/)). The first `connect()` must run
from a user gesture (button tap); later reconnects are silent.

**Desktop** — needs **libusb-1.0** at runtime and the ST-Link on WinUSB
(Windows):

```sh
sudo apt install libusb-1.0-0     # Debian/Ubuntu
brew install libusb               # macOS
# Windows: put libusb-1.0.dll beside the executable (or on PATH)
```

The loader searches the executable's directory, then system/Homebrew locations.

## Usage

### Connecting

```dart
final probe = Probe()..onLog(print);
final target = await probe.connect(mode);
```

`ConnectMode`:

- `normal` — plain SWD attach.
- `underReset` — assert nRST, attach, catch the reset vector, release. Best
  default for firmware that reconfigures/disables SWD.
- `guided` — hold reset, emit a prompt, wait for `probe.continueConnect()`, then
  attach (for a manual step between assert and release).
- `attachRace` — hammer the attach until the boot window is caught (SWD disabled
  very early); cut & re-apply power, `probe.abort()` to stop.

### Debugging

```dart
await probe.halt();
for (final r in await probe.readRegisters()) print('${r.name} = ${hex(r.value)}');
final ram = await probe.readMemory(0x20000000, 256);
await probe.writeMemory(0x20000000, Uint8List.fromList([1, 2, 3, 4]));
await probe.step();
await probe.resume();
```

### Programming

```dart
final image = await probe.readFlash();              // dump (default 128 KB)
await probe.program(0x08000000, bytes);             // erase + write + verify
await probe.erase(0x08000000, bytes.length);        // just erase
await probe.writeFlash(0x08000000, bytes);          // write, no erase
await probe.verifyFlash(0x08000000, bytes);         // verify only
await probe.eraseAll();                             // mass erase
```

### Read protection (RDP / FAP)

```dart
final state = await probe.readProtection();          // enabled? which level?
await probe.setProtection(true);                     // lock
await probe.setProtection(false);                    // unlock — MASS-ERASES the chip
```

Disabling protection always erases the whole flash — that's the security
guarantee, and the only way back into a device its own firmware locked.

## How it works (and notable details)

- **Flash loaders** — the STM32F1 FPEC programs in 16-bit halfwords and the
  AT32 FMC in 32-bit words, so tiny hand-verified Thumb routines run from target
  SRAM to hit the required width; register sequences follow OpenOCD's own
  drivers.
- **Watchdog freeze** — on attach it sets `DBGMCU_CR |= 0x307` so a running
  IWDG/WWDG can't reset the target mid-operation (the classic "core did not
  halt" failure). Same as OpenOCD's target cfg.
- **Endpoints** — matches OpenOCD: IN `0x81`; OUT `0x01` for V2-1/V3, `0x02` for
  V1/V2 and unrecognized clones.

## Extending

- **New flash driver** — implement `FlashDriver` and select it in a target map
  (see `detectTarget` + `Probe`).
- **New probe** — implement `UsbTransport` and provide open/reacquire.

## Credits

The register-level flash/debug logic is a faithful Dart port of the author's
`openocd-ts` project, whose sequences follow OpenOCD's `stm32f1x.c` / `artery.c`
(behavior only — no GPL code copied). ST-Link protocol knowledge is from
publicly documented sources.

## License

MIT.
