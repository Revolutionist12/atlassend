#include "atlas_overlay_window.h"

#include <flutter_windows.h>

#include <optional>
#include <variant>
#include <vector>

namespace {

const wchar_t kClassName[] = L"ATLASSEND_OVERLAY_WINDOW";
const wchar_t kWindowTitle[] = L"AtlasSend Overlay";
const char kWindowChannel[] = "atlassend/overlay_window";
const char kHostChannel[] = "atlassend/overlay_host";

// Width of the overlay column in logical pixels. The height is the work area
// of the primary monitor, so cards can fly in from the bottom edge.
const int kLogicalWidth = 640;

std::unique_ptr<AtlasOverlayWindow> g_overlay;
std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_host_channel;

// Makes the client area fully transparent wherever Flutter draws alpha = 0.
// Same technique as window_manager's SetBackgroundColor (already shipped with
// this app): an accent policy with a fully transparent gradient color.
void MakeTransparent(HWND hwnd) {
  const HINSTANCE module = LoadLibrary(TEXT("user32.dll"));
  if (!module) {
    return;
  }
  struct ACCENTPOLICY {
    int nAccentState;
    int nFlags;
    int nColor;
    int nAnimationId;
  };
  struct WINCOMPATTRDATA {
    int nAttribute;
    PVOID pData;
    ULONG ulDataSize;
  };
  typedef BOOL(WINAPI * SetWindowCompositionAttributeFn)(HWND,
                                                         WINCOMPATTRDATA*);
  const auto set_attribute = reinterpret_cast<SetWindowCompositionAttributeFn>(
      GetProcAddress(module, "SetWindowCompositionAttribute"));
  if (set_attribute) {
    const int kAccentEnableTransparentGradient = 2;
    const int kWcaAccentPolicy = 19;
    ACCENTPOLICY policy = {kAccentEnableTransparentGradient, 2, 0, 0};
    WINCOMPATTRDATA data = {kWcaAccentPolicy, &policy, sizeof(policy)};
    set_attribute(hwnd, &data);
  }
  FreeLibrary(module);
}

int ToInt(const flutter::EncodableValue& value) {
  if (const auto* v = std::get_if<int32_t>(&value)) {
    return *v;
  }
  if (const auto* v = std::get_if<int64_t>(&value)) {
    return static_cast<int>(*v);
  }
  if (const auto* v = std::get_if<double>(&value)) {
    return static_cast<int>(*v);
  }
  return 0;
}

const flutter::EncodableValue* Find(const flutter::EncodableMap& map,
                                    const char* key) {
  const auto it = map.find(flutter::EncodableValue(key));
  return it == map.end() ? nullptr : &it->second;
}

}  // namespace

AtlasOverlayWindow::AtlasOverlayWindow() {}

AtlasOverlayWindow::~AtlasOverlayWindow() {
  channel_ = nullptr;
  controller_ = nullptr;
  if (hwnd_) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
}

bool AtlasOverlayWindow::Create() {
  const HINSTANCE instance = GetModuleHandle(nullptr);
  WNDCLASS window_class{};
  window_class.lpfnWndProc = AtlasOverlayWindow::WndProc;
  window_class.hInstance = instance;
  window_class.lpszClassName = kClassName;
  window_class.hCursor = LoadCursor(nullptr, IDC_ARROW);
  window_class.hbrBackground = nullptr;
  // Fails with ERROR_CLASS_ALREADY_EXISTS on the second start, which is fine.
  RegisterClass(&window_class);

  RECT work{};
  SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  const HMONITOR monitor = MonitorFromRect(&work, MONITOR_DEFAULTTOPRIMARY);
  const double scale = FlutterDesktopGetDpiForMonitor(monitor) / 96.0;
  const int width = static_cast<int>(kLogicalWidth * scale);
  const int height = work.bottom - work.top;
  const int x = work.left + ((work.right - work.left) - width) / 2;
  const int y = work.top;

  // WS_EX_NOACTIVATE: never takes focus. WS_EX_TOOLWINDOW: no taskbar button,
  // not in Alt+Tab. WS_EX_TOPMOST: always on top.
  hwnd_ = CreateWindowEx(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
                         kClassName, kWindowTitle, WS_POPUP, x, y, width,
                         height, nullptr, nullptr, instance, this);
  if (!hwnd_) {
    return false;
  }
  MakeTransparent(hwnd_);
  // Nothing is visible or clickable until the Dart side reports card bounds.
  SetWindowRgn(hwnd_, CreateRectRgn(0, 0, 0, 0), FALSE);

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint("atlasOverlayMain");
  // The overlay's Dart code gets its own thread. On the shared platform thread
  // its animations stall whenever the main window's isolate is busy (measured
  // in the spike: 39 ms frame gaps vs. 8.8 ms on a separate thread).
  project.set_ui_thread_policy(flutter::UIThreadPolicy::RunOnSeparateThread);
  controller_ =
      std::make_unique<flutter::FlutterViewController>(width, height, project);
  if (!controller_->engine() || !controller_->view()) {
    return false;
  }
  const HWND child = controller_->view()->GetNativeWindow();
  SetParent(child, hwnd_);
  MoveWindow(child, 0, 0, width, height, TRUE);

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      controller_->engine()->messenger(), kWindowChannel,
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });

  // Shown right away, but with an empty region: nothing is painted and nothing
  // is clickable. It must not stay hidden, because Flutter produces no frames
  // for a hidden window, and the Dart side needs a frame to report the bounds
  // of the first card.
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  return true;
}

void AtlasOverlayWindow::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());

  if (call.method_name() == "setRegion" && args) {
    // Union of the given rectangles (client pixels). Everything outside is
    // neither painted nor hit-tested: clicks there reach the window below.
    const HRGN region = CreateRectRgn(0, 0, 0, 0);
    const auto* rects_value = Find(*args, "rects");
    const auto* rects =
        rects_value ? std::get_if<flutter::EncodableList>(rects_value)
                    : nullptr;
    if (rects) {
      for (size_t i = 0; i + 3 < rects->size(); i += 4) {
        const HRGN rect =
            CreateRectRgn(ToInt((*rects)[i]), ToInt((*rects)[i + 1]),
                          ToInt((*rects)[i + 2]), ToInt((*rects)[i + 3]));
        CombineRgn(region, region, rect, RGN_OR);
        DeleteObject(rect);
      }
    }
    // The system owns |region| after a successful call.
    if (!SetWindowRgn(hwnd_, region, TRUE)) {
      DeleteObject(region);
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (call.method_name() == "raise") {
    // Called when the first card appears: back to the top of the topmost band
    // (another topmost window may have been opened since), without activating.
    SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE | SWP_SHOWWINDOW);
    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
}

// static
LRESULT CALLBACK AtlasOverlayWindow::WndProc(HWND window, UINT message,
                                             WPARAM wparam,
                                             LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    const auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(window, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
  }
  auto* that = reinterpret_cast<AtlasOverlayWindow*>(
      GetWindowLongPtr(window, GWLP_USERDATA));
  if (that && that->hwnd_ == window) {
    return that->MessageHandler(window, message, wparam, lparam);
  }
  return DefWindowProc(window, message, wparam, lparam);
}

LRESULT AtlasOverlayWindow::MessageHandler(HWND window, UINT message,
                                           WPARAM wparam,
                                           LPARAM lparam) noexcept {
  if (controller_) {
    const std::optional<LRESULT> handled =
        controller_->HandleTopLevelWindowProc(window, message, wparam, lparam);
    if (handled) {
      return *handled;
    }
  }

  switch (message) {
    case WM_MOUSEACTIVATE:
      // A click on a card must not activate the overlay.
      return MA_NOACTIVATE;
    case WM_FONTCHANGE:
      if (controller_) {
        controller_->engine()->ReloadSystemFonts();
      }
      break;
    case WM_SIZE:
      if (controller_ && controller_->view()) {
        MoveWindow(controller_->view()->GetNativeWindow(), 0, 0,
                   LOWORD(lparam), HIWORD(lparam), TRUE);
      }
      break;
  }
  return DefWindowProc(window, message, wparam, lparam);
}

// static
void AtlasOverlayHost::Register(flutter::FlutterEngine* main_engine) {
  g_host_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          main_engine->messenger(), kHostChannel,
          &flutter::StandardMethodCodec::GetInstance());
  g_host_channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "start") {
      if (!g_overlay) {
        g_overlay = std::make_unique<AtlasOverlayWindow>();
        if (!g_overlay->Create()) {
          g_overlay = nullptr;
        }
      }
      result->Success(flutter::EncodableValue(g_overlay != nullptr));
      return;
    }
    if (call.method_name() == "stop") {
      g_overlay = nullptr;
      result->Success(flutter::EncodableValue(true));
      return;
    }
    result->NotImplemented();
  });
}

// static
void AtlasOverlayHost::Shutdown() {
  g_overlay = nullptr;
  g_host_channel = nullptr;
}
