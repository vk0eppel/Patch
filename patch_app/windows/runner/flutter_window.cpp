#include "flutter_window.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// EncodableValue stores ints as int32_t or int64_t depending on magnitude —
// an opaque ARGB color (alpha 0xFF) always exceeds INT32_MAX, so it arrives
// as int64_t while a small pulse count arrives as int32_t. Accept either.
uint32_t EncodableToUint32(const flutter::EncodableValue& value) {
  if (const auto* i32 = std::get_if<int32_t>(&value)) {
    return static_cast<uint32_t>(*i32);
  }
  if (const auto* i64 = std::get_if<int64_t>(&value)) {
    return static_cast<uint32_t>(*i64);
  }
  return 0;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  flash_overlay_ = std::make_unique<FlashOverlayWindow>();
  flutter::MethodChannel<flutter::EncodableValue> flash_channel(
      flutter_controller_->engine()->messenger(),
      "com.patch.app/flash_overlay", &flutter::StandardMethodCodec::GetInstance());
  flash_channel.SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "pulse") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        flutter::EncodableMap::const_iterator argb_it, count_it;
        if (!args ||
            (argb_it = args->find(flutter::EncodableValue("argb"))) ==
                args->end() ||
            (count_it = args->find(flutter::EncodableValue("pulseCount"))) ==
                args->end()) {
          result->Error("bad_args", "Expected argb/pulseCount");
          return;
        }
        flash_overlay_->Pulse(
            EncodableToUint32(argb_it->second),
            static_cast<int>(EncodableToUint32(count_it->second)),
            GetHandle());
        result->Success();
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  flash_overlay_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
