# Changelog

## 0.2.0

Internal cleanup; one small breaking API change.

- **Breaking:** `TargetInfo.family` is now a `TargetFamily` enum (`stm32` / `at32`
  / `nrf` / `unknown`) instead of a string. Use `family.name` for display.
- `TargetInfo` gains an explicit `word` flag (true for GD32E103's 32-bit-word
  FPEC), replacing the previous overloading of `programAlign == 4` as the driver
  selector; `_makeDriver` now switches on the family enum.
- Refactor: shared FPEC plumbing (work-buffer sizing, BSY wait, read-back
  verify) factored out of the AT32/STM32 drivers into a common base.
- No behaviour change; renamed the internal probe field for accuracy.

## 0.1.1

- GigaDevice **GD32F103** and **GD32E103** support. GD32F103 is an STM32F103
  FPEC clone and flashes on the existing STM32F1 path (device id 0x410/0x414,
  RDP 0xA5), now labelled as such.
- **GD32E103** (Cortex-M4) is detected by its GigaDevice **FMC_PID** signature
  (`0x40022100 == 0x48424333`) and programmed in **32-bit words** via the shared
  FPEC driver (`Stm32f1Flash(word: true)`) — its device id is ambiguous and it
  needs word-width flash unlike the halfword STM32F1/GD32F103. RDP is the usual
  0xA5. (Detection/values reverse-engineered from a GD flasher firmware; the
  GD32E103 flash path is a faithful port, not yet bench-verified.)

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
- Flash drivers for **STM32F0/F1/F3** (FPEC, RDP), Artery **AT32F415** (FMC,
  FAP), and Nordic **nRF51/nRF52** (NVMC, APPROTECT/RBPCONF). Read-protection
  get/set; disabling always forces the chip's mandatory mass-erase.
- **Locked-nRF recovery** over CTRL-AP (`Probe.recoverNordic()` /
  `nrfCtrlApEraseAll`): `ERASEALL`-unlock a part whose APPROTECT has disabled
  the AHB-AP, without attaching. Guarded by the CTRL-AP IDR. Raw DAP-register and
  multi-AP open/close primitives (`Stlink.readDapReg`/`writeDapReg`/`initAp`).
- Target auto-detection with per-family flash base/size, page size, and program
  width; raw `.bin` and Intel **HEX** (`parseIntelHex`) inputs.
- Watchdog freeze on attach (DBGMCU_CR) for STM32/AT32 so a running IWDG/WWDG
  can't reset the target mid-operation.
- ST-Link endpoint selection matching OpenOCD (V2-1/V3 → OUT 0x01; V1/V2/unknown
  → OUT 0x02; IN 0x81).
