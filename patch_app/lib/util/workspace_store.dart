import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Persistent panel visibility and window geometry for the local Operator's
/// workspace. Stored in `workspace.json` next to `patch.toml` so all Patch
/// state files live in one directory.
class WorkspaceState {
  final bool showPeers;
  // null = never explicitly toggled; home_screen derives the default from
  // whether any macros are configured (Global or Channel).
  final bool? showMacros;
  final double? windowX;
  final double? windowY;
  final double? windowWidth;
  final double? windowHeight;

  const WorkspaceState({
    this.showPeers = true,
    this.showMacros,
    this.windowX,
    this.windowY,
    this.windowWidth,
    this.windowHeight,
  });

  factory WorkspaceState.fromJson(Map<String, dynamic> json) => WorkspaceState(
        showPeers: json['showPeers'] as bool? ?? true,
        showMacros: json['showMacros'] as bool?,
        windowX: (json['windowX'] as num?)?.toDouble(),
        windowY: (json['windowY'] as num?)?.toDouble(),
        windowWidth: (json['windowWidth'] as num?)?.toDouble(),
        windowHeight: (json['windowHeight'] as num?)?.toDouble(),
      );

  Map<String, dynamic> toJson() => {
        'showPeers': showPeers,
        if (showMacros != null) 'showMacros': showMacros,
        if (windowX != null) 'windowX': windowX,
        if (windowY != null) 'windowY': windowY,
        if (windowWidth != null) 'windowWidth': windowWidth,
        if (windowHeight != null) 'windowHeight': windowHeight,
      };

  WorkspaceState copyWith({
    bool? showPeers,
    bool? showMacros,
    double? windowX,
    double? windowY,
    double? windowWidth,
    double? windowHeight,
  }) =>
      WorkspaceState(
        showPeers: showPeers ?? this.showPeers,
        showMacros: showMacros ?? this.showMacros,
        windowX: windowX ?? this.windowX,
        windowY: windowY ?? this.windowY,
        windowWidth: windowWidth ?? this.windowWidth,
        windowHeight: windowHeight ?? this.windowHeight,
      );
}

/// Mirrors the Rust `config::data_dir()` computation so both sides resolve to
/// the same directory without a bridge round-trip before `runApp`.
///
/// On macOS under the App Sandbox, `HOME` is remapped to the container
/// directory, so this produces the same path as the Rust `dirs` crate.
String computeDataDir() {
  if (Platform.isMacOS || Platform.isIOS) {
    final home = Platform.environment['HOME'] ?? '.';
    return '$home/Library/Application Support/Patch';
  }
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'] ?? '.';
    return '$appData\\Patch';
  }
  // Linux / Android: XDG first, then ~/.local/share.
  final xdg = Platform.environment['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) return '$xdg/Patch';
  final home = Platform.environment['HOME'] ?? '.';
  return '$home/.local/share/Patch';
}

class WorkspaceStore {
  final String _path;

  WorkspaceStore(String dataDir) : _path = '$dataDir${Platform.isWindows ? '\\' : '/'}workspace.json';

  Future<WorkspaceState> load() async {
    try {
      final f = File(_path);
      if (!await f.exists()) return const WorkspaceState();
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return WorkspaceState.fromJson(json);
    } catch (e) {
      debugPrint('WorkspaceStore: load failed — $e');
      return const WorkspaceState();
    }
  }

  // Fire-and-forget: called on every panel toggle and on the window debounce
  // timer. Failures are logged but never propagated — a missed workspace save
  // is not show-critical.
  void save(WorkspaceState state) {
    unawaited(_write(state));
  }

  Future<void> _write(WorkspaceState state) async {
    try {
      await File(_path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(state.toJson()),
      );
    } catch (e) {
      debugPrint('WorkspaceStore: save failed — $e');
    }
  }
}
