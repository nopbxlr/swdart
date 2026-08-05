/// swdart — program and debug ARM Cortex-M microcontrollers over ST-Link,
/// in pure Dart.
///
/// The USB transport is chosen automatically per platform: **WebUSB** in the
/// browser and **libusb** on desktop. Supported targets today: STM32F103 and
/// Artery AT32F415 (flash + read-protection); the probe, target-detection and
/// flash-driver layers are abstracted so more can be added.
///
/// Start with [Probe]:
/// ```dart
/// import 'package:swdart/swdart.dart';
///
/// final probe = Probe()..onLog(print);
/// final target = await probe.connect(ConnectMode.underReset);
/// print('connected to ${target.name}');
/// await probe.program(0x08000000, firmwareBytes); // erase + write + verify
/// await probe.resetRun();
/// await probe.disconnect();
/// ```
library;

// ── primary API ──────────────────────────────────────────────────────────
export 'src/probe.dart' show Probe, ConnectMode, CoreRegister;
export 'src/targets.dart' show TargetInfo, detectTarget;
export 'src/flash.dart'
    show FlashDriver, ProgressFn, ProtectionState, ProtectionResult, At32Flash, Stm32f1Flash, NrfFlash;
export 'src/intel_hex.dart' show FlashImage, parseIntelHex;
export 'src/util.dart' show SwdException, hex;

// ── lower-level building blocks (custom flows / new drivers / new probes) ──
export 'src/stlink.dart'
    show Stlink, ProbeVersion, regR0, regR1, regR2, regR3, regSp, regLr, regPc, regXpsr;
export 'src/cortexm.dart' show CortexM;
export 'src/transport.dart' show UsbTransport;
export 'src/transport_open.dart' show requestStlink, reacquireStlink;
