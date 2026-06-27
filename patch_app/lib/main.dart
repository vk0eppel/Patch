import 'dart:io' show Platform;
import 'dart:ui' show AppExitResponse, Size, Offset, PlatformDispatcher;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'bridge/bridge_client.dart';
import 'screens/home_screen.dart';
import 'store/app_store.dart';
import 'theme/patch_theme.dart';
import 'util/orientation_lock.dart';
import 'util/workspace_store.dart';

bool get _isDesktop =>
    !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

/// Returns true when placing a window of [windowSize] at [pos] (logical px)
/// would keep at least part of it visible on a connected screen.
///
/// dart:ui [Display] exposes physical size + DPR but not layout positions, so
/// we can't know the exact virtual coordinate space. We approximate it as a
/// rectangle spanning (−maxDim … totalLogicalWidth) × (−maxDim … maxLogicalHeight),
/// where maxDim is the largest logical dimension seen across all displays.
/// This covers the most common failure case — a window saved on a second
/// monitor that is now disconnected — while remaining permissive enough for
/// monitors arranged to the left or above the primary.
bool _positionOnScreen(Offset pos, Size windowSize) {
  final displays = PlatformDispatcher.instance.displays;
  if (displays.isEmpty) return true;

  double totalLogicalW = 0;
  double maxLogicalH = 0;
  for (final d in displays) {
    final dpr = d.devicePixelRatio > 0 ? d.devicePixelRatio : 1.0;
    totalLogicalW += d.size.width / dpr;
    final h = d.size.height / dpr;
    if (h > maxLogicalH) maxLogicalH = h;
  }
  final maxDim = totalLogicalW > maxLogicalH ? totalLogicalW : maxLogicalH;

  // A window rect that overlaps the estimated virtual screen region at all.
  final winRight = pos.dx + windowSize.width;
  final winBottom = pos.dy + windowSize.height;
  return winRight > -maxDim &&
      pos.dx < totalLogicalW + maxDim &&
      winBottom > -maxDim &&
      pos.dy < maxLogicalH + maxDim;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Lock to landscape on iPad — the fixed-width multi-panel layout is unusable
  // in portrait. Done before runApp so it's in effect for the first frame. No-op
  // on desktop and iPhone (see shouldLockLandscape).
  final isIOS = !kIsWeb && Platform.isIOS;
  final view = WidgetsBinding.instance.platformDispatcher.views.first;
  final shortestSide = (view.physicalSize / view.devicePixelRatio).shortestSide;
  if (shouldLockLandscape(isIOS: isIOS, shortestSide: shortestSide)) {
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  WorkspaceState initialWorkspace = const WorkspaceState();
  WorkspaceStore? workspaceStore;

  if (_isDesktop) {
    await windowManager.ensureInitialized();
    final store = WorkspaceStore(computeDataDir());
    workspaceStore = store;
    initialWorkspace = await store.load();

    final ws = initialWorkspace;
    // Apply saved geometry before the window is shown (the MainFlutterWindow
    // override of order(_:relativeTo:) keeps it hidden until show() is called).
    final ww = ws.windowWidth;
    final wh = ws.windowHeight;
    if (ww != null && wh != null) {
      await windowManager.setSize(Size(ww, wh));
    }
    final wx = ws.windowX;
    final wy = ws.windowY;
    if (wx != null && wy != null) {
      // Only restore position if the window would land on a connected screen.
      // dart:ui gives physical size + DPR per display but no layout positions,
      // so we estimate total logical screen space as the sum of widths × margin.
      // Monitors to the left/above appear at negative logical coordinates, hence
      // the -maxDim lower bound. This catches the common "disconnected second
      // monitor" case without platform-specific screen-geometry queries.
      if (_positionOnScreen(Offset(wx, wy), Size(ww ?? 900, wh ?? 600))) {
        await windowManager.setPosition(Offset(wx, wy));
      }
    }
    await windowManager.show();
    await windowManager.focus();
  }

  runApp(PatchApp(
    workspaceStore: workspaceStore,
    initialWorkspace: initialWorkspace,
  ));
}

class PatchApp extends StatefulWidget {
  final WorkspaceStore? workspaceStore;
  final WorkspaceState initialWorkspace;

  const PatchApp({
    super.key,
    this.workspaceStore,
    this.initialWorkspace = const WorkspaceState(),
  });

  @override
  State<PatchApp> createState() => _PatchAppState();
}

class _PatchAppState extends State<PatchApp> {
  late final BridgeClient _bridge;
  late final AppStore _store;
  late final AppLifecycleListener _lifecycle;
  bool _connected = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bridge = BridgeClient();
    _store = AppStore(_bridge);
    // `onExitRequested` is AWAITED by the framework before the app actually
    // terminates (Cmd-Q / last-window-close on desktop), so the /patch/bye UDP
    // send has time to flush — unlike the fire-and-forget `detached` event,
    // which usually loses the race with process teardown. `onDetach` stays as a
    // best-effort fallback for platforms that don't route an exit request.
    _lifecycle = AppLifecycleListener(
      onExitRequested: _onExitRequested,
      onDetach: () {
        _bridge.shutdown();
      },
    );
    _connect();
  }

  Future<AppExitResponse> _onExitRequested() async {
    try {
      // Bounded so a slow/failed goodbye never hangs the quit.
      await _bridge.shutdown().timeout(const Duration(seconds: 1));
    } catch (_) {}
    return AppExitResponse.exit;
  }

  Future<void> _connect() async {
    setState(() => _error = null);
    try {
      await _bridge.connect();
      // Engine is up — load initial shared state into the store.
      _store.start();
      if (mounted) setState(() => _connected = true);
    } catch (e) {
      // A failed engine boot (socket bind failure, corrupt patch.toml, denied
      // permission) must not leave the user on an endless spinner.
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _store.dispose();
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PATCH',
      debugShowCheckedModeBanner: false,
      theme: PatchTheme.dark(),
      // Provide the shared store ABOVE the Navigator (via builder) so pushed
      // routes — e.g. the settings screen — can read it too (candidate 2).
      builder: (context, child) => AppStoreScope(store: _store, child: child!),
      home: _gate(),
    );
  }

  Widget _gate() {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                const SizedBox(height: 16),
                const Text(
                  'Could not start the PATCH engine',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (!_connected) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Connecting to PATCH engine…'),
            ],
          ),
        ),
      );
    }
    return HomeScreen(
      bridge: _bridge,
      workspaceStore: widget.workspaceStore,
      initialWorkspace: widget.initialWorkspace,
    );
  }
}
