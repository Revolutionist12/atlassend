#ifndef RUNNER_ATLAS_OVERLAY_WINDOW_H_
#define RUNNER_ATLAS_OVERLAY_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_engine.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>

// AtlasSend: the window that shows incoming files as cards.
//
// It is frameless, transparent, always on top and never takes focus. It hosts
// a SECOND Flutter engine running the Dart entrypoint `atlasOverlayMain`
// (app/lib/atlassend/overlay/). No plugins are registered on that engine.
//
// The Dart side controls the window through the "atlassend/overlay_window"
// method channel:
//   setRegion({rects: [l, t, r, b, ...]})  client pixels; everything outside
//                                           is neither painted nor clickable
//   raise()                                 back on top of other topmost windows
class AtlasOverlayWindow {
 public:
  AtlasOverlayWindow();
  ~AtlasOverlayWindow();

  // Creates the window (shown, but with an empty region) and starts the
  // overlay engine.
  bool Create();

 private:
  static LRESULT CALLBACK WndProc(HWND window, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  LRESULT MessageHandler(HWND window, UINT message, WPARAM wparam,
                         LPARAM lparam) noexcept;
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  HWND hwnd_ = nullptr;
  std::unique_ptr<flutter::FlutterViewController> controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

// Lets the MAIN engine start and stop the overlay on demand through the
// "atlassend/overlay_host" method channel (methods: start, stop), so the
// second engine only costs memory while cards are on screen.
class AtlasOverlayHost {
 public:
  // Called once with the main engine, right after its plugins are registered.
  static void Register(flutter::FlutterEngine* main_engine);

  // Destroys the overlay (if any). Called before the main engine goes away.
  static void Shutdown();
};

#endif  // RUNNER_ATLAS_OVERLAY_WINDOW_H_
