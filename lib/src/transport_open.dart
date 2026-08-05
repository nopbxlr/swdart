// Selects the USB transport for the platform: WebUSB in the browser, native
// libusb-1.0 (direct FFI) on desktop.
export 'transport_web.dart' if (dart.library.io) 'transport_native.dart';
