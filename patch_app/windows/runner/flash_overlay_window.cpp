#include "flash_overlay_window.h"

#include <algorithm>

namespace {

constexpr wchar_t kWindowClassName[] = L"PatchFlashOverlayWindow";
constexpr UINT_PTR kPulseTimerId = 1;
constexpr UINT kLitMs = 200;
constexpr UINT kDarkMs = 150;
constexpr int kBorderWidth = 8;
constexpr BYTE kFillAlpha = 38;  // ~15% of 255.

}  // namespace

FlashOverlayWindow::FlashOverlayWindow() {}

FlashOverlayWindow::~FlashOverlayWindow() {
  if (hwnd_) {
    KillTimer(hwnd_, kPulseTimerId);
    DestroyWindow(hwnd_);
  }
}

void FlashOverlayWindow::EnsureWindow() {
  if (hwnd_) return;

  WNDCLASS wc = {};
  wc.lpfnWndProc = DefWindowProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kWindowClassName;
  // Ignoring the result: a second registration attempt (e.g. a second
  // FlashOverlayWindow instance) fails with ERROR_CLASS_ALREADY_EXISTS,
  // which is fine — the class is already usable.
  RegisterClass(&wc);

  hwnd_ = CreateWindowEx(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
          WS_EX_TOPMOST,
      kWindowClassName, L"", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr,
      GetModuleHandle(nullptr), nullptr);
  SetWindowLongPtr(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
}

void FlashOverlayWindow::Pulse(uint32_t argb, int pulse_count,
                                HWND near_window) {
  EnsureWindow();

  HMONITOR monitor = MonitorFromWindow(near_window ? near_window : hwnd_,
                                        MONITOR_DEFAULTTOPRIMARY);
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  GetMonitorInfo(monitor, &monitor_info);
  const RECT& bounds = monitor_info.rcMonitor;

  color_ = RGB((argb >> 16) & 0xFF, (argb >> 8) & 0xFF, argb & 0xFF);
  remaining_ = std::clamp(pulse_count, 3, 7);

  // KillTimer alone doesn't guarantee a WM_TIMER already posted to the
  // queue won't still fire — drain it explicitly so a sequence in flight
  // never bleeds a stray step into the new one.
  KillTimer(hwnd_, kPulseTimerId);
  MSG msg;
  while (PeekMessage(&msg, hwnd_, WM_TIMER, WM_TIMER, PM_REMOVE)) {
  }

  SetWindowPos(hwnd_, HWND_TOPMOST, bounds.left, bounds.top,
               bounds.right - bounds.left, bounds.bottom - bounds.top,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);

  Paint(true);
  ScheduleStep(kLitMs);
}

void FlashOverlayWindow::ScheduleStep(UINT delay_ms) {
  SetTimer(hwnd_, kPulseTimerId, delay_ms, TimerProc);
}

void CALLBACK FlashOverlayWindow::TimerProc(HWND hwnd, UINT /*message*/,
                                             UINT_PTR id_event,
                                             DWORD /*time*/) {
  KillTimer(hwnd, id_event);
  auto* self = reinterpret_cast<FlashOverlayWindow*>(
      GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self) self->RunStep();
}

void FlashOverlayWindow::RunStep() {
  if (lit_) {
    Paint(false);
    ScheduleStep(kDarkMs);
  } else if (--remaining_ > 0) {
    Paint(true);
    ScheduleStep(kLitMs);
  } else {
    ShowWindow(hwnd_, SW_HIDE);
  }
}

void FlashOverlayWindow::Paint(bool lit) {
  lit_ = lit;

  RECT rect;
  GetWindowRect(hwnd_, &rect);
  const int width = rect.right - rect.left;
  const int height = rect.bottom - rect.top;
  if (width <= 0 || height <= 0) return;

  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // Top-down DIB.
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;

  HDC screen_dc = GetDC(nullptr);
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  void* bits = nullptr;
  HBITMAP bitmap =
      CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  HBITMAP old_bitmap = static_cast<HBITMAP>(SelectObject(mem_dc, bitmap));

  if (bits) {
    auto* pixels = static_cast<uint32_t*>(bits);
    const size_t pixel_count = static_cast<size_t>(width) * height;
    if (!lit) {
      ZeroMemory(pixels, pixel_count * sizeof(uint32_t));
    } else {
      const BYTE r = GetRValue(color_);
      const BYTE g = GetGValue(color_);
      const BYTE b = GetBValue(color_);
      // UpdateLayeredWindow with ULW_ALPHA expects premultiplied alpha.
      const uint32_t fill_pixel =
          (static_cast<uint32_t>(kFillAlpha) << 24) |
          (static_cast<uint32_t>(r * kFillAlpha / 255) << 16) |
          (static_cast<uint32_t>(g * kFillAlpha / 255) << 8) |
          static_cast<uint32_t>(b * kFillAlpha / 255);
      const uint32_t border_pixel = 0xFF000000u |
                                     (static_cast<uint32_t>(r) << 16) |
                                     (static_cast<uint32_t>(g) << 8) | b;

      for (int y = 0; y < height; ++y) {
        uint32_t* row = pixels + static_cast<size_t>(y) * width;
        const bool border_row = y < kBorderWidth || y >= height - kBorderWidth;
        for (int x = 0; x < width; ++x) {
          const bool border_col =
              x < kBorderWidth || x >= width - kBorderWidth;
          row[x] = (border_row || border_col) ? border_pixel : fill_pixel;
        }
      }
    }
  }

  POINT origin = {rect.left, rect.top};
  SIZE size = {width, height};
  POINT src_origin = {0, 0};
  BLENDFUNCTION blend = {};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;

  UpdateLayeredWindow(hwnd_, screen_dc, &origin, &size, mem_dc, &src_origin, 0,
                       &blend, ULW_ALPHA);

  SelectObject(mem_dc, old_bitmap);
  DeleteObject(bitmap);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
}
