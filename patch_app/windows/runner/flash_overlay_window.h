#ifndef RUNNER_FLASH_OVERLAY_WINDOW_H_
#define RUNNER_FLASH_OVERLAY_WINDOW_H_

#include <windows.h>

#include <cstdint>

// Borderless, click-through, always-on-top window that pulses the whole
// screen alongside the in-app Flash pulse (#80/#81) — see ARCHITECTURE.md's
// Flash section. Fully transparent and hidden while idle, so it never shows
// up as a blank window in the taskbar/Alt-Tab switcher or a screenshot.
class FlashOverlayWindow {
 public:
  FlashOverlayWindow();
  ~FlashOverlayWindow();

  // Re-resolves the monitor covering |near_window| on every call (never
  // caches a display from an earlier Flash), then (re)starts a pulse
  // sequence of |pulse_count| (clamped 3-7) on/off cycles in the resolved
  // ARGB color. Any sequence already in flight is cancelled outright (its
  // pending timer killed and drained, not just superseded) before the new
  // one starts, so rapid repeated flashes restart cleanly instead of
  // overlapping — mirroring the Dart `_FlashLayer`'s pulse-restart behavior.
  void Pulse(uint32_t argb, int pulse_count, HWND near_window);

 private:
  static void CALLBACK TimerProc(HWND hwnd, UINT message, UINT_PTR id_event,
                                  DWORD time);

  void EnsureWindow();
  void Paint(bool lit);
  void RunStep();
  void ScheduleStep(UINT delay_ms);

  HWND hwnd_ = nullptr;
  COLORREF color_ = RGB(0, 0, 0);
  int remaining_ = 0;
  bool lit_ = false;
};

#endif  // RUNNER_FLASH_OVERLAY_WINDOW_H_
