// Nordic nRF51/nRF52 "unbrick" over CTRL-AP.
//
// When a chip's APPROTECT (nRF52) / RBPCONF (nRF51) is enabled, the normal
// AHB-AP debug access is disabled — you can't halt, read memory, or reach the
// NVMC, so the ordinary erase path is unreachable. Nordic parts still expose a
// custom CTRL-AP (access port #1) that survives protection and can trigger a
// whole-chip ERASEALL, which clears the protection. This is the SWD equivalent
// of the Artery FAP-disable rescue.
import 'stlink.dart';
import 'util.dart';

// CTRL-AP is access port #1 on both nRF51 and nRF52.
const _ctrlApSel = 1;

// CTRL-AP register offsets (addressed directly as the DAP register address).
const _ctrlReset = 0x00; //          write 1 to hold the core in reset, 0 to release
const _ctrlEraseAll = 0x04; //       write 1 to erase all code + UICR
const _ctrlEraseAllStatus = 0x08; // 0 = ready/done, 1 = erase in progress
const _ctrlApprotectStatus = 0x0c; //bit0: 1 = not protected, 0 = protected
const _ctrlIdr = 0xfc; //            AP identity register

/// Nordic CTRL-AP identity — refuse to erase anything that doesn't match.
const _nordicCtrlApIdr = 0x02880000;

/// Result of a CTRL-AP recovery attempt.
class NrfRecoverResult {
  NrfRecoverResult({required this.idr, required this.unprotected});

  /// The CTRL-AP IDR that was read (confirms a Nordic part).
  final int idr;

  /// True if APPROTECTSTATUS reports the part is no longer protected.
  final bool unprotected;
}

/// Erase and unlock a fully protected Nordic part over CTRL-AP.
///
/// [probe] must be open with SWD already entered (the debug port answers even
/// when APPROTECT is on). This does NOT need — and does not use — the AHB-AP, so
/// it works on a chip that [Probe.connect] can't attach to. On success the chip
/// is blank and debuggable.
///
/// Requires ST-Link V2 firmware **J28+** or any **V3** (multi-AP support).
/// Throws [SwdException] if the CTRL-AP isn't a Nordic one, so it's safe to call
/// against an unknown target: a non-Nordic AP is rejected before any erase.
Future<NrfRecoverResult> nrfCtrlApEraseAll(Stlink probe, {void Function(String line)? log}) async {
  void emit(String s) => log?.call(s);

  if (!probe.hasApInit) {
    throw SwdException(
      'CTRL-AP recovery needs ST-Link V2 firmware J28+ (or a V3 probe); '
      'this probe is ${probe.version.text}. Update the ST-Link firmware and retry.',
    );
  }

  await probe.initAp(_ctrlApSel);
  try {
    final idr = await probe.readDapReg(_ctrlApSel, _ctrlIdr);
    emit('[recover] CTRL-AP IDR ${hex(idr)}');
    if (idr != _nordicCtrlApIdr) {
      throw SwdException(
        'CTRL-AP IDR ${hex(idr)} is not a Nordic part (${hex(_nordicCtrlApIdr)}); '
        'refusing to mass-erase.',
      );
    }

    // Hold the core in reset so it can't run while the flash is erased.
    await probe.writeDapReg(_ctrlApSel, _ctrlReset, 1);
    await probe.writeDapReg(_ctrlApSel, _ctrlEraseAll, 1);
    emit('[recover] ERASEALL started…');

    final deadline = DateTime.now().add(const Duration(seconds: 15));
    for (;;) {
      await sleep(50);
      final status = await probe.readDapReg(_ctrlApSel, _ctrlEraseAllStatus);
      if (status == 0) break;
      if (DateTime.now().isAfter(deadline)) {
        throw SwdException('CTRL-AP ERASEALL did not finish within 15 s (status ${hex(status)})');
      }
    }

    // Release the core from reset; the erased UICR now reads unprotected.
    await probe.writeDapReg(_ctrlApSel, _ctrlReset, 0);

    final prot = await probe.readDapReg(_ctrlApSel, _ctrlApprotectStatus);
    final unprotected = (prot & 1) != 0;
    emit('[recover] APPROTECTSTATUS ${hex(prot)} — ${unprotected ? 'unprotected' : 'still protected'}');
    if (!unprotected) {
      throw SwdException(
        'ERASEALL completed but the part still reports protected; power-cycle the board and retry.',
      );
    }
    return NrfRecoverResult(idr: idr, unprotected: true);
  } finally {
    try {
      await probe.closeAp(_ctrlApSel);
    } catch (_) {
      // best-effort cleanup
    }
  }
}
