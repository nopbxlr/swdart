// Save bytes to disk: native shows a save dialog and writes a file; web triggers
// a browser download. Returns a human-readable destination, or null if cancelled.
export 'save_io.dart' if (dart.library.js_interop) 'save_web.dart';
