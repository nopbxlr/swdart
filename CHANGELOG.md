# Changelog

## 0.1.0

Initial release.

- `Probe` facade: connect (normal / under-reset / guided / attach-race), debug
  (halt/resume/step, read/write core registers, read/write arbitrary memory,
  reset-halt/reset-run), and program (read/erase/write/verify flash, high-level
  `program()`, read-protection get/set).
- ST-Link APIv2 protocol over a pluggable USB transport: **WebUSB**
  (`dart:js_interop`) on web, **libusb-1.0** (`dart:ffi`) on desktop, selected
  by conditional import.
- Cortex-M debug control and hand-verified Thumb SRAM flash loaders.
- Flash drivers for STM32F103 (FPEC) and Artery AT32F415 (FMC), including
  RDP/FAP read-protection and the mass-erase "unbrick" path.
- Watchdog freeze on attach (DBGMCU_CR) so a running IWDG/WWDG can't reset the
  target mid-operation.
- ST-Link endpoint selection matching OpenOCD (V2-1/V3 → OUT 0x01; V1/V2/unknown
  → OUT 0x02; IN 0x81).
