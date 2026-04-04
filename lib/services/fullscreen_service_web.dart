import 'package:web/web.dart' as web;

void requestFullscreen() {
  try {
    web.document.documentElement?.requestFullscreen();
  } catch (e) {
    // Ignore fullscreen errors
  }
}

void exitFullscreen() {
  try {
    web.document.exitFullscreen();
  } catch (e) {
    // Ignore fullscreen exit errors
  }
}
