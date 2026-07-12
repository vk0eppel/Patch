import 'dart:async';

import '../models/channel.dart';
import '../models/config.dart';
import '../models/events.dart';
import '../models/message.dart';
import '../src/rust/api.dart' as rust;
import '../src/rust/frb_generated.dart';
import '../src/rust/osc/types.dart' as rust_osc;
import '../src/rust/state/channel.dart' as rust_channel;
import '../src/rust/state/config.dart' as rust_config;
import '../src/rust/transport.dart' as rust_transport;

/// Façade over the `flutter_rust_bridge`-generated engine API.
///
/// The Flutter app used to talk to `patch-core` over a local TCP socket and
/// consume newline-JSON events. Now `patch-core` is linked directly into the
/// app as a Rust library (see `patch-core/src/api.rs`). This class preserves
/// the legacy method surface + `Stream<Map<String, dynamic>>` event shape so
/// `home_screen.dart` and `settings_screen.dart` don't need to change.
///
/// The command seam (#177) is this class's *implicit* Dart interface: UI code
/// depends on `BridgeClient`, production satisfies it with this FFI-calling
/// class, and tests with `FakeBridge` (`test/support/fake_bridge.dart`,
/// `Fake implements BridgeClient`) — two adapters at one seam, no separate
/// abstract class needed. `command_seam_test.dart` pins that no screen or
/// widget imports the generated bindings directly.
///
/// Lifecycle: construct → `await connect()` → use. `dispose()` to clean up.
class BridgeClient {
  /// Typed engine-push stream — the sole event channel. Reads return `Future`s
  /// and commands throw; the legacy stringly-typed map stream is gone (#59,
  /// ADR-0004).
  final _pushController = StreamController<PatchEvent>.broadcast();

  StreamSubscription<rust.PatchAppEvent>? _engineSub;
  bool _connected = false;

  /// `RustLib.init()` may only be called once per process — FRB throws on a
  /// second call. Tracked separately from [_connected] so a retry after a
  /// failed `rust.init()` (e.g. socket bind error) doesn't re-init the lib.
  static bool _rustLibInitialized = false;

  /// Typed engine pushes — consumed by the AppStore and the screens.
  Stream<PatchEvent> get pushes => _pushController.stream;

  /// Boot the Rust engine and start forwarding pushes onto [pushes].
  /// Safe to call again after a failed attempt (used by the boot Retry path).
  Future<void> connect() async {
    if (_connected) return;
    if (!_rustLibInitialized) {
      await RustLib.init();
      _rustLibInitialized = true;
    }
    await rust.init();
    _engineSub = rust.subscribeEvents().listen(_forwardEngineEvent);
    _connected = true;
  }

  /// Forward an engine push onto the typed [pushes] stream only (slice 1.4,
  /// ADR-0004) — the legacy map-push path is gone now that both screens consume
  /// the sealed [PatchEvent]. `patchEventFromRust` returns null for variants
  /// intentionally not surfaced to the UI (e.g. MessageAcked).
  void _forwardEngineEvent(rust.PatchAppEvent event) {
    final typed = patchEventFromRust(event);
    if (typed != null) _pushController.add(typed);
  }

  // ── Commands (legacy fire-and-forget shape) ──────────────────────────────

  /// The current channel list. Returns directly (owned by `AppStore` —
  /// candidate 2, ADR-0004); throws on failure.
  Future<List<PatchChannel>> getChannels() async {
    final channels = await rust.getChannels();
    return channels.map(PatchChannel.fromRust).toList();
  }

  /// The current peer list. Returns directly (owned by `AppStore` — candidate
  /// 2, ADR-0004); throws on failure.
  Future<List<PeerInfo>> getPeers() async {
    final peers = await rust.getPeers();
    return peers.map(PeerInfo.fromRust).toList();
  }

  /// Fetch [channelId]'s recent message history. Returns directly (owned by
  /// `AppStore` — candidate 2, ADR-0004); throws on failure.
  Future<List<PatchMessage>> getMessages(
    String channelId, {
    int limit = 500,
  }) async {
    final messages = await rust.getMessages(channelId: channelId, limit: limit);
    return messages.map(PatchMessage.fromRust).toList();
  }

  /// Available network interfaces (name + ip). Returns directly (single
  /// consumer — settings); throws on failure (#59, ADR-0004).
  Future<List<({String name, String ip})>> getInterfaces() async {
    final ifaces = await rust.getInterfaces();
    return ifaces.map((i) => (name: i.name, ip: i.ip)).toList();
  }

  /// The current config snapshot. Returns directly (owned by `AppStore` —
  /// candidate 2, ADR-0004); throws on failure.
  Future<AppConfig> getConfig() async {
    final cfg = await rust.getConfig();
    return AppConfig.fromRust(cfg);
  }

  /// Set (or clear) the self-assigned role. Pass null/empty to clear it. Throws
  /// on failure; the caller refetches config via the store (`_applyConfigChange`).
  Future<void> setRole(String? role) {
    final trimmed = role?.trim();
    return rust.setRole(
      role: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
    );
  }

  /// Remove dynamic peers (OscBeacon / Mdns) not heard from within [maxAgeSecs].
  /// ManualIp / static peers are never removed. Throws on failure.
  Future<void> clearStalePeers({int maxAgeSecs = 60}) =>
      rust.clearStalePeers(maxAgeSecs: BigInt.from(maxAgeSecs));

  /// Upsert a Macro into either home, keyed on [channelId] (#186): non-null
  /// is a Channel Macro, null is a Global Macro. The Macro travels as one
  /// [MacroMessage]; this adapter is where it fans out to the FFI arguments.
  ///
  /// [originalLabel] is the macro's label before this edit — pass it when
  /// editing an existing macro (even if the label didn't change) so a rename
  /// updates that macro in place instead of creating a new one. Omit (null)
  /// only when creating a brand-new macro.
  Future<void> upsertMacro({
    String? channelId,
    String? originalLabel,
    required MacroMessage macro,
  }) => rust.upsertMacro(
    channelId: channelId,
    originalLabel: originalLabel,
    label: macro.label,
    payload: macro.payload,
    priority: macro.priority,
    keyBinding: macro.keyBinding,
    midiNote: macro.midiNote,
    midiCc: macro.midiCc,
    osc: oscTargetFromMacroOsc(macro.osc),
  );

  /// Fire an arbitrary OSC message to external gear (the dual-action half of an
  /// OSC macro — the Patch message is sent separately via [sendMessage]).
  /// Throws on failure.
  Future<void> sendOscMacro(
    String address,
    int port,
    String path,
    String? arg, [
    MacroOscArgType argType = MacroOscArgType.string,
  ]) => rust.sendOscMacro(
    address: address,
    port: port,
    path: path,
    arg: arg,
    argType: _toRustArgType(argType),
  );

  /// Names of available MIDI input ports (for a future port-selector UI).
  /// Returns an empty list on failure — a non-critical read with a sensible
  /// fallback, so it neither throws nor surfaces an error.
  Future<List<String>> getMidiPorts() async {
    try {
      return await rust.getMidiPorts();
    } catch (_) {
      return const [];
    }
  }

  // ── Global macros (shown on every channel; fired on the current channel) ────

  /// Push the UI's current channel selection to the engine so a MIDI-triggered
  /// global macro fires on the same channel(s) as a tap/F-key. Fire-and-forget.
  Future<void> setSelectedChannels(List<String> ids) =>
      rust.setSelectedChannels(ids: ids);

  /// Tell the engine which peer's DM thread is open (null when none), so a
  /// MIDI-triggered macro routes to that peer the same way a tap/F-key would.
  Future<void> setDmTarget(String? peerId) => rust.setDmTarget(peerId: peerId);

  /// Adopt offered channels — merge (adds only ids not already present).
  /// Returns the number of channels actually added; throws on failure.
  Future<int> adoptChannels(List<PatchChannel> channels) =>
      rust.adoptChannels(channels: channels.map(_channelToRust).toList());

  /// Classify offered global Macros against what this machine already has —
  /// for the import preview dialog. Read-only; throws nothing it can't recover
  /// from since it never mutates state.
  Future<List<MacroImportOutcome>> previewGlobalMacros(
    List<MacroMessage> globalMacros,
  ) async {
    final outcomes = await rust.previewGlobalMacros(
      globalMacros: globalMacros.map(_macroToRust).toList(),
    );
    return outcomes.map(MacroImportOutcome.fromRust).toList();
  }

  /// Adopt offered global Macros — merge (adds new ones, strips colliding
  /// bindings rather than excluding the Macro, drops invalid-OSC ones).
  /// Returns the same per-item classification as [previewGlobalMacros]; throws
  /// on failure.
  Future<List<MacroImportOutcome>> adoptGlobalMacros(
    List<MacroMessage> globalMacros,
  ) async {
    final outcomes = await rust.adoptGlobalMacros(
      globalMacros: globalMacros.map(_macroToRust).toList(),
    );
    return outcomes.map(MacroImportOutcome.fromRust).toList();
  }

  /// Save the current layout as a show file. Returns its slug + name; throws on
  /// failure. The caller reports the result.
  Future<({String slug, String name})> saveShowFile(String name) async {
    final s = await rust.saveShowFile(name: name);
    return (slug: s.slug, name: s.name);
  }

  /// Import a show file from an arbitrary file path (from a file picker) and
  /// apply it. Returns the loaded name + channel count; throws on failure. The
  /// caller refreshes (channels also refresh via the ChannelsChanged push).
  Future<({String name, int channelCount})> importLayout(String path) async {
    final s = await rust.importLayout(path: path);
    return (name: s.name, channelCount: s.channelCount);
  }

  /// Load a saved show file by slug and apply it. Returns the loaded name +
  /// channel count; throws on failure.
  Future<({String name, int channelCount})> loadShowFile(String slug) async {
    final s = await rust.loadShowFile(slug: slug);
    return (name: s.name, channelCount: s.channelCount);
  }

  /// Saved show files. Returns directly (single consumer — the show-files
  /// dialog); throws on failure (#59, ADR-0004).
  Future<List<ShowFileMeta>> listShowFiles() async {
    final list = await rust.listShowFiles();
    return list.map(ShowFileMeta.fromRust).toList();
  }

  /// Set the presence heartbeat interval (seconds). The engine validates 1–60
  /// and applies it live (the discovery loop re-reads the cadence each cycle).
  Future<void> setHeartbeatInterval(int secs) =>
      rust.setHeartbeatInterval(secs: BigInt.from(secs));

  // ── Messaging & flash ───────────────────────────────────────────────────

  /// Send a channel message. Returns the message id; throws on failure.
  Future<String> sendMessage({
    required String channelId,
    required String payload,
    int priority = 1,
  }) => rust.sendMessage(
    channelId: channelId,
    payload: payload,
    priority: priority,
  );

  /// Send a Direct Message to [peerId]. Returns the message id; throws on failure.
  Future<String> sendDirectMessage({
    required String peerId,
    required String payload,
    int priority = 1,
  }) => rust.sendDirectMessage(
    peerId: peerId,
    payload: payload,
    priority: priority,
  );

  /// Flash a Channel (urgent attention signal, no message content).
  Future<void> sendFlash({required String channelId}) =>
      rust.sendFlash(channelId: channelId);

  /// Flash a Peer's Direct Message thread.
  Future<void> sendDmFlash({required String peerId}) =>
      rust.sendDmFlash(peerId: peerId);

  /// Clear the message buffer for [channelId], or all channels when null.
  Future<void> clearMessages({String? channelId}) =>
      rust.clearMessages(channelId: channelId);

  /// Export messages to a CSV file at [path]; all channels when [channelId]
  /// is null.
  Future<void> exportMessages({String? channelId, required String path}) =>
      rust.exportMessages(channelId: channelId, path: path);

  // ── Macro firing (engine-owned routing, ADR-0009) ───────────────────────

  /// Fire an identified Macro — Channel Macro when [channelId] is set, Global
  /// Macro when null. Routing lives engine-side in `macro_router`.
  Future<void> fireMacro({String? channelId, required String label}) =>
      rust.fireMacro(channelId: channelId, label: label);

  /// Fire whatever Macro [label]'s F-key resolves to (engine-owned precedence).
  Future<bool> fireKeyBinding({required String label}) =>
      rust.fireKeyBinding(label: label);

  // ── Identity & behavior settings ────────────────────────────────────────

  Future<void> setClientName({required String name}) =>
      rust.setClientName(name: name);

  /// Apply any subset of the scalar behavior settings in one engine command
  /// (#179). Null fields are left untouched; the engine clamps ranged values
  /// and persists once.
  Future<void> patchConfig({
    bool? flashOnMessage,
    bool? flashOnCritical,
    bool? audibleAlert,
    bool? flashWholeScreen,
    bool? hideKeyboard,
    int? flashCount,
    int? macrosColumns,
  }) => rust.patchConfig(
    patch: rust_config.ConfigPatch(
      flashOnCritical: flashOnCritical,
      flashOnMessage: flashOnMessage,
      flashCount: flashCount,
      macrosColumns: macrosColumns,
      hideKeyboard: hideKeyboard,
      audibleAlert: audibleAlert,
      flashWholeScreen: flashWholeScreen,
    ),
  );

  /// Restore the scalar behavior settings to their factory defaults — the
  /// engine owns the default values (#180); no literals cross the seam.
  Future<void> resetBehaviorConfig() => rust.resetBehaviorConfig();

  // ── Network settings ────────────────────────────────────────────────────

  /// Pin Patch to interface [name] (ADR-0011 — mandatory pinning).
  Future<void> setInterface({String? name}) => rust.setInterface(name: name);

  Future<void> setOscPort({required int port}) => rust.setOscPort(port: port);

  Future<void> addStaticPeer({
    required String address,
    required int port,
    String? label,
  }) => rust.addStaticPeer(address: address, port: port, label: label);

  Future<void> removeStaticPeer({required String address, required int port}) =>
      rust.removeStaticPeer(address: address, port: port);

  // ── Channel & Macro CRUD ────────────────────────────────────────────────

  Future<void> upsertChannel({
    required String id,
    String? displayName,
    String? color,
  }) => rust.upsertChannel(id: id, displayName: displayName, color: color);

  Future<void> deleteChannel({required String id}) =>
      rust.deleteChannel(id: id);

  /// Per-channel flash overrides; null fields are left unchanged.
  Future<void> setChannelFlash({
    required String channelId,
    bool? flashOnCritical,
    bool? flashOnMessage,
    int? flashCount,
  }) => rust.setChannelFlash(
    channelId: channelId,
    flashOnCritical: flashOnCritical,
    flashOnMessage: flashOnMessage,
    flashCount: flashCount,
  );

  /// Restore the default channel set (destructive; confirmed by the UI).
  Future<void> resetChannels() => rust.resetChannels();

  Future<void> deleteMacro({
    required String channelId,
    required String label,
  }) => rust.deleteMacro(channelId: channelId, label: label);

  /// Reorder a channel's macros to match [orderedLabels] (drag-to-reorder).
  Future<void> reorderMacros({
    required String channelId,
    required List<String> orderedLabels,
  }) => rust.reorderMacros(channelId: channelId, orderedLabels: orderedLabels);

  Future<void> deleteGlobalMacro({required String label}) =>
      rust.deleteGlobalMacro(label: label);

  Future<void> resetGlobalMacros() => rust.resetGlobalMacros();

  Future<void> reorderGlobalMacros({required List<String> orderedLabels}) =>
      rust.reorderGlobalMacros(orderedLabels: orderedLabels);

  // ── Peer channel/macro exchange ─────────────────────────────────────────

  /// Ask a Peer for its Channel layout — replies arrive as a ChannelsOffered
  /// push; nothing is auto-applied.
  Future<void> requestChannels({required String peerId}) =>
      rust.requestChannels(peerId: peerId);

  /// Ask a Peer for its Global Macros — replies arrive as a
  /// GlobalMacrosOffered push; nothing is auto-applied.
  Future<void> requestGlobalMacros({required String peerId}) =>
      rust.requestGlobalMacros(peerId: peerId);

  // ── Show files ──────────────────────────────────────────────────────────

  /// Export the current layout as a show file to an arbitrary [path].
  Future<void> exportLayout({required String path, required String name}) =>
      rust.exportLayout(path: path, name: name);

  Future<void> deleteShowFile({required String slug}) =>
      rust.deleteShowFile(slug: slug);

  /// Announce departure so peers drop us promptly (best-effort). Safe to call
  /// more than once and before/without a full [dispose].
  Future<void> shutdown() async {
    if (!_connected) return;
    try {
      await rust.shutdown();
    } catch (_) {
      // Best-effort — never block shutdown on a failed goodbye.
    }
  }

  Future<void> dispose() async {
    await shutdown();
    await _engineSub?.cancel();
    await _pushController.close();
  }
}

// ── Conversion helpers ──────────────────────────────────────────────────────
//
// Builds the plain Dart models the screens already render straight from the
// FRB-generated types — one conversion instead of the previous Rust struct →
// legacy JSON Map → model round trip (the Map added nothing: the models'
// fields already mirror these structs field-for-field).

/// Pure wire→model mapping for engine pushes (slice 1.1). The seam the typed
/// event surface is tested through — callable without booting the engine, since
/// the FRB event values are plain data classes.
///
/// Exhaustive `switch` *expression* over the generated FFI event type: a new
/// engine event variant won't compile here until it is mapped or explicitly
/// dropped (`=> null`). Returns null for variants intentionally not surfaced to
/// the UI. See ADR-0004.
PatchEvent? patchEventFromRust(rust.PatchAppEvent event) => switch (event) {
  rust.PatchAppEvent_Message(:final field0) => MessageReceived(
    PatchMessage.fromRust(field0),
  ),
  rust.PatchAppEvent_MessageDelivery(
    :final messageId,
    :final delivered,
    :final total,
    :final failed,
    :final failedPeers,
  ) =>
    DeliveryUpdated(
      messageId,
      MessageDeliveryStatus(
        delivered: delivered,
        total: total,
        failed: failed,
        failedPeers: failedPeers,
      ),
    ),
  rust.PatchAppEvent_ChannelFlash(:final field0) => Flashed(
    channelId: field0.channelId,
    senderId: field0.senderId.toString(),
    senderName: field0.senderName,
  ),
  rust.PatchAppEvent_PeerExpired(:final peerId) => PeerExpired(peerId),
  rust.PatchAppEvent_ChannelsOffered(
    :final fromPeerId,
    :final fromName,
    :final channels,
  ) =>
    ChannelsOffered(
      fromPeerId: fromPeerId,
      fromName: fromName,
      channels: channels.map(PatchChannel.fromRust).toList(),
    ),
  rust.PatchAppEvent_GlobalMacrosOffered(
    :final fromPeerId,
    :final fromName,
    :final globalMacros,
  ) =>
    GlobalMacrosOffered(
      fromPeerId: fromPeerId,
      fromName: fromName,
      globalMacros: globalMacros.map(MacroMessage.fromRust).toList(),
    ),
  rust.PatchAppEvent_ClientNameChanged(:final name) => ClientNameChanged(name),
  rust.PatchAppEvent_PermissionDenied(:final context) => PermissionDenied(
    context,
  ),
  // Payload intentionally dropped — presence lacks address/status, so the
  // UI refetches regardless (ADR-0004).
  rust.PatchAppEvent_PeerUpdated() => const PeersChanged(),
  rust.PatchAppEvent_ChannelListUpdated() => const ChannelsChanged(),
  // Intentionally not surfaced — no UI consumer reads the per-Peer ack.
  rust.PatchAppEvent_MessageAcked() => null,
  // This subscriber lagged and lost events — the store must refetch.
  rust.PatchAppEvent_Desynced() => const Resynced(),
};

// Inverse of the fromRust factories on the Dart model classes — rebuilds the
// typed FRB structs from
// a `PatchChannel` so an adopted offer (delivered as `PatchChannel`s in
// `channels_offered`) can be passed back into `adopt_channels`.
rust_channel.Channel _channelToRust(PatchChannel c) => rust_channel.Channel(
  id: c.id,
  displayName: c.displayName,
  // Pad to 8 hex digits (full ARGB) before dropping the alpha byte —
  // padding after the substring would corrupt low colour values.
  color:
      '#${c.color.toARGB32().toRadixString(16).padLeft(8, '0').substring(2)}',
  macros: c.macros.map(_macroToRust).toList(),
  flashOnCritical: c.flashOnCritical,
  flashOnMessage: c.flashOnMessage,
  flashCount: c.flashCount,
);

rust_channel.MacroMessage _macroToRust(MacroMessage s) =>
    rust_channel.MacroMessage(
      label: s.label,
      payload: s.payload,
      keyBinding: s.keyBinding,
      priority: s.priority,
      midiNote: s.midiNote,
      midiCc: s.midiCc,
      osc: oscTargetFromMacroOsc(s.osc),
    );

/// The one place a `MacroOsc` becomes a wire `OscTarget` (#181). The
/// empty-collapse rule lives here: a target missing its address, port, or
/// path is no target at all (null), never a half-built struct; an empty
/// `arg` collapses to null. The validator rejects such targets before any
/// save — this is the seam's own guarantee, independent of the caller.
rust_channel.OscTarget? oscTargetFromMacroOsc(MacroOsc? o) {
  if (o == null || o.address.isEmpty || o.port == 0 || o.path.isEmpty) {
    return null;
  }
  return rust_channel.OscTarget(
    address: o.address,
    port: o.port,
    path: o.path,
    arg: (o.arg == null || o.arg!.isEmpty) ? null : o.arg,
    argType: _toRustArgType(o.argType),
  );
}

rust_osc.OscArgKind _toRustArgType(MacroOscArgType t) => switch (t) {
  MacroOscArgType.string => rust_osc.OscArgKind.string,
  MacroOscArgType.int => rust_osc.OscArgKind.int,
  MacroOscArgType.float => rust_osc.OscArgKind.float,
};

// Keep this import alive — `InterfaceInfo` is referenced only via `rust.`,
// not via the prefix, but the unused-import lint would still trip without it.
// ignore: unused_element
final _keepTransportImport = rust_transport.InterfaceInfo;
