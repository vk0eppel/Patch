import 'dart:async';
import 'dart:ui' show Color;

import '../models/channel.dart';
import '../models/config.dart';
import '../models/events.dart';
import '../models/message.dart';
import '../src/rust/api.dart' as rust;
import '../src/rust/frb_generated.dart';
import '../src/rust/osc/types.dart' as rust_osc;
import '../src/rust/state/channel.dart' as rust_channel;
import '../src/rust/state/config.dart' as rust_config;
import '../src/rust/state/peer.dart' as rust_peer;
import '../src/rust/state/show_file.dart' as rust_show_file;
import '../src/rust/transport.dart' as rust_transport;

/// Façade over the `flutter_rust_bridge`-generated engine API.
///
/// The Flutter app used to talk to `patch-core` over a local TCP socket and
/// consume newline-JSON events. Now `patch-core` is linked directly into the
/// app as a Rust library (see `patch-core/src/api.rs`). This class preserves
/// the legacy method surface + `Stream<Map<String, dynamic>>` event shape so
/// `home_screen.dart` and `settings_screen.dart` don't need to change.
///
/// Lifecycle: construct → `await connect()` → use. `dispose()` to clean up.
class BridgeClient {
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();

  /// Typed engine-push stream (slice 1.1). Emitted *alongside* the legacy map
  /// [events] during migration — consumers move onto this on their own
  /// schedule (slices 1.2/1.3); slice 1.4 deletes the map-push path. See
  /// ADR-0004.
  final _pushController = StreamController<PatchEvent>.broadcast();

  StreamSubscription<rust.PatchAppEvent>? _engineSub;
  bool _connected = false;

  /// `RustLib.init()` may only be called once per process — FRB throws on a
  /// second call. Tracked separately from [_connected] so a retry after a
  /// failed `rust.init()` (e.g. socket bind error) doesn't re-init the lib.
  static bool _rustLibInitialized = false;

  /// Stream of legacy-shaped events: `{"event": "<type>", ...}`.
  Stream<Map<String, dynamic>> get events => _eventController.stream;

  /// Typed engine pushes — the migration target for the legacy [events] map.
  Stream<PatchEvent> get pushes => _pushController.stream;

  /// Boot the Rust engine and start forwarding events into [events].
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

  void _emit(Map<String, dynamic> event) => _eventController.add(event);

  void _emitError(Object e) =>
      _emit({'event': 'error', 'message': e.toString()});

  // ── Commands (legacy fire-and-forget shape) ──────────────────────────────

  /// Send a Message on a channel. Returns the message id; throws on failure
  /// (callers wrap in `runGuarded`). Slice 1.2: return/throw instead of the
  /// old `ack_send`/`error` events (ADR-0004).
  Future<String> sendMessage({
    required String channelId,
    required String payload,
    int priority = 1,
  }) =>
      rust.sendMessage(
        channelId: channelId,
        payload: payload,
        priority: priority,
      );

  /// Send a direct (peer-to-peer) message to one peer. Stored locally under a
  /// `dm:<peerId>` key and unicast only to that peer. Returns the message id;
  /// throws on failure.
  Future<String> sendDirectMessage({
    required String peerId,
    required String payload,
    int priority = 1,
  }) =>
      rust.sendDirectMessage(
        peerId: peerId,
        payload: payload,
        priority: priority,
      );

  /// Flash a channel. Throws on failure.
  Future<void> sendFlash(String channelId) =>
      rust.sendFlash(channelId: channelId);

  /// Send a direct flash (attention ping) to one peer — unicast only; flashes
  /// the recipient's DM thread with us (and our own thread locally). Throws on
  /// failure.
  Future<void> sendDmFlash(String peerId) => rust.sendDmFlash(peerId: peerId);

  Future<void> getChannels() async {
    try {
      final channels = await rust.getChannels();
      _emit({
        'event': 'channels',
        'data': channels.map(_channelFromRust).toList(),
      });
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> getPeers() async {
    try {
      final peers = await rust.getPeers();
      _emit({'event': 'peers', 'data': peers.map(_peerFromRust).toList()});
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> getMessages(String channelId, {int limit = 500}) async {
    try {
      final messages = await rust.getMessages(
        channelId: channelId,
        limit: limit,
      );
      _emit({
        'event': 'messages',
        'channel_id': channelId,
        'data': messages.map(_messageFromRust).toList(),
      });
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> getInterfaces() async {
    try {
      final ifaces = await rust.getInterfaces();
      _emit({
        'event': 'interfaces',
        'data': ifaces.map((i) => {'name': i.name, 'ip': i.ip}).toList(),
      });
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> getConfig() async {
    try {
      final cfg = await rust.getConfig();
      _emit({'event': 'config', 'data': _configFromRust(cfg)});
    } catch (e) {
      _emitError(e);
    }
  }

  /// Change the network interface (empty/'auto' → all interfaces). Throws on
  /// failure. No restart needed: the socket always binds 0.0.0.0; the NIC only
  /// scopes the discovery broadcast, which the engine re-reads each heartbeat.
  Future<void> setInterface(String name) =>
      rust.setInterface(name: name.isEmpty ? null : name);

  /// Set the local Operator's display name. Throws on failure;
  /// `client_name_changed` is emitted by the engine event bus.
  Future<void> setClientName(String name) => rust.setClientName(name: name);

  /// Set (or clear) the self-assigned role. Pass null/empty to clear it.
  /// Refetches config so the change propagates to both screens; throws on
  /// failure.
  Future<void> setRole(String? role) async {
    final trimmed = role?.trim();
    await rust.setRole(role: (trimmed == null || trimmed.isEmpty) ? null : trimmed);
    await getConfig();
  }

  /// Remove dynamic peers (OscBeacon / Mdns) not heard from within [maxAgeSecs].
  /// ManualIp / static peers are never removed. Throws on failure.
  Future<void> clearStalePeers({int maxAgeSecs = 60}) =>
      rust.clearStalePeers(maxAgeSecs: BigInt.from(maxAgeSecs));

  /// Add a Static Peer. Throws on failure; the caller refetches config
  /// (`_applyConfigChange`) — slice 1.3 (ADR-0004).
  Future<void> addStaticPeer(String address, int port, {String? label}) =>
      rust.addStaticPeer(address: address, port: port, label: label);

  /// Remove a Static Peer. Throws on failure.
  Future<void> removeStaticPeer(String address, int port) =>
      rust.removeStaticPeer(address: address, port: port);

  Future<void> upsertChannel(String id, String displayName, String color) =>
      rust.upsertChannel(id: id, displayName: displayName, color: color);

  Future<void> upsertMacro({
    required String channelId,
    required String label,
    required String payload,
    String? keyBinding,
    int priority = 1,
    int? midiNote,
    int? midiCc,
    String? oscAddress,
    int? oscPort,
    String? oscPath,
    String? oscArg,
    MacroOscArgType oscArgType = MacroOscArgType.string,
  }) =>
      rust.upsertMacro(
        channelId: channelId,
        label: label,
        payload: payload,
        priority: priority,
        keyBinding: keyBinding,
        midiNote: midiNote,
        midiCc: midiCc,
        osc: _buildOsc(oscAddress, oscPort, oscPath, oscArg, oscArgType),
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
  ]) =>
      rust.sendOscMacro(
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

  Future<void> deleteMacro({
    required String channelId,
    required String label,
  }) =>
      rust.deleteMacro(channelId: channelId, label: label);

  /// Reorder a channel's macros to match [labels] (drag-to-reorder).
  Future<void> reorderMacros(String channelId, List<String> labels) =>
      rust.reorderMacros(channelId: channelId, orderedLabels: labels);

  // ── Global macros (shown on every channel; fired on the current channel) ────

  Future<void> upsertGlobalMacro({
    required String label,
    required String payload,
    String? keyBinding,
    int priority = 1,
    int? midiNote,
    int? midiCc,
    String? oscAddress,
    int? oscPort,
    String? oscPath,
    String? oscArg,
    MacroOscArgType oscArgType = MacroOscArgType.string,
  }) =>
      rust.upsertGlobalMacro(
        label: label,
        payload: payload,
        priority: priority,
        keyBinding: keyBinding,
        midiNote: midiNote,
        midiCc: midiCc,
        osc: _buildOsc(oscAddress, oscPort, oscPath, oscArg, oscArgType),
      );

  /// Build a typed `OscTarget` from flat UI fields — null unless address, port,
  /// and path are all present (an empty `arg` collapses to null).
  rust_channel.OscTarget? _buildOsc(
    String? address,
    int? port,
    String? path,
    String? arg,
    MacroOscArgType argType,
  ) {
    if (address == null || address.isEmpty || port == null || path == null || path.isEmpty) {
      return null;
    }
    return rust_channel.OscTarget(
      address: address,
      port: port,
      path: path,
      arg: (arg == null || arg.isEmpty) ? null : arg,
      argType: _toRustArgType(argType),
    );
  }

  /// Push the UI's current channel selection to the engine so a MIDI-triggered
  /// global macro fires on the same channel(s) as a tap/F-key. Fire-and-forget.
  Future<void> setSelectedChannels(List<String> ids) =>
      rust.setSelectedChannels(ids: ids);

  /// Tell the engine which peer's DM thread is open (null when none), so a
  /// MIDI-triggered macro routes to that peer the same way a tap/F-key would.
  Future<void> setDmTarget(String? peerId) => rust.setDmTarget(peerId: peerId);

  Future<void> deleteGlobalMacro(String label) =>
      rust.deleteGlobalMacro(label: label);

  /// Restore the factory default global macros (replaces the current set).
  Future<void> resetGlobalMacros() => rust.resetGlobalMacros();

  /// Reorder global macros to match [labels] (drag-to-reorder).
  Future<void> reorderGlobalMacros(List<String> labels) =>
      rust.reorderGlobalMacros(orderedLabels: labels);

  Future<void> deleteChannel(String id) => rust.deleteChannel(id: id);

  /// Export messages to a CSV file at [path].
  /// Pass [channelId] to export a single channel, or null for all channels.
  Future<void> exportMessages({String? channelId, required String path}) =>
      rust.exportMessages(channelId: channelId, path: path);

  /// Clear messages for [channelId], or all channels when null. Throws on
  /// failure; the caller updates its local message buffer.
  Future<void> clearMessages({String? channelId}) =>
      rust.clearMessages(channelId: channelId);

  /// Ask a peer (by id) for its channel layout. The reply arrives asynchronously
  /// as a `channels_offered` event (not auto-applied — the UI previews + merges).
  Future<void> requestChannels(String peerId) =>
      rust.requestChannels(peerId: peerId);

  /// Adopt offered channels — merge (adds only ids not already present).
  /// Returns the number of channels actually added; throws on failure.
  Future<int> adoptChannels(List<PatchChannel> channels) =>
      rust.adoptChannels(channels: channels.map(_channelToRust).toList());

  /// Reset all channels to factory defaults (AUDIO · RF · LIGHTING · VIDEO ·
  /// STAGE). Throws on failure. ChannelListUpdated is emitted by the engine, so
  /// the screens refresh via the ChannelsChanged push.
  Future<void> resetChannels() => rust.resetChannels();

  /// Save the current layout as a show file. Returns its slug + name; throws on
  /// failure. The caller reports the result.
  Future<({String slug, String name})> saveShowFile(String name) async {
    final s = await rust.saveShowFile(name: name);
    return (slug: s.slug, name: s.name);
  }

  /// Export the current layout to an arbitrary file path (from a file picker).
  /// Throws on failure.
  Future<void> exportLayout(String path, {String name = ''}) =>
      rust.exportLayout(path: path, name: name);

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

  Future<void> listShowFiles() async {
    try {
      final list = await rust.listShowFiles();
      _emit({
        'event': 'show_files',
        'data': list.map(_showFileMetaFromRust).toList(),
      });
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> deleteShowFile(String slug) => rust.deleteShowFile(slug: slug);

  Future<void> setFlashOnCritical(bool enabled) =>
      rust.setFlashOnCritical(enabled: enabled);

  Future<void> setFlashOnMessage(bool enabled) =>
      rust.setFlashOnMessage(enabled: enabled);

  /// Set the global flash pulse count (3–7).
  Future<void> setFlashCount(int count) => rust.setFlashCount(count: count);

  /// These setters refetch config so the change propagates to both screens;
  /// each throws on failure (callers wrap in `runGuarded`).
  Future<void> setHideKeyboard(bool enabled) async {
    await rust.setHideKeyboard(enabled: enabled);
    await getConfig();
  }

  Future<void> setAudibleAlert(bool enabled) async {
    await rust.setAudibleAlert(enabled: enabled);
    await getConfig();
  }

  Future<void> setMacrosColumns(int columns) async {
    await rust.setMacrosColumns(columns: columns);
    await getConfig();
  }

  /// Set the presence heartbeat interval (seconds). The engine validates 1–60
  /// and applies it live (the discovery loop re-reads the cadence each cycle).
  Future<void> setHeartbeatInterval(int secs) async {
    await rust.setHeartbeatInterval(secs: BigInt.from(secs));
    await getConfig();
  }

  /// Set the OSC UDP port (1024–65535). The engine rebinds the socket live; a
  /// bind failure (e.g. port already in use) throws and leaves the persisted
  /// port unchanged.
  Future<void> setOscPort(int port) async {
    await rust.setOscPort(port: port);
    await getConfig();
  }

  /// Set per-channel flash overrides. Pass 0 as [flashCount] to clear the
  /// per-channel override (revert to global). Throws on failure.
  Future<void> setChannelFlash(
    String channelId, {
    bool? flashOnCritical,
    bool? flashOnMessage,
    int? flashCount,
  }) =>
      rust.setChannelFlash(
        channelId: channelId,
        flashOnCritical: flashOnCritical,
        flashOnMessage: flashOnMessage,
        flashCount: flashCount,
      );

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
    await _eventController.close();
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
      rust.PatchAppEvent_Message(:final field0) =>
        MessageReceived(_messageFromRust(field0)),
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
          channels: channels.map(_channelFromRust).toList(),
        ),
      rust.PatchAppEvent_ClientNameChanged(:final name) =>
        ClientNameChanged(name),
      rust.PatchAppEvent_PermissionDenied(:final context) =>
        PermissionDenied(context),
      // Payload intentionally dropped — presence lacks address/status, so the
      // UI refetches regardless (ADR-0004).
      rust.PatchAppEvent_PeerUpdated() => const PeersChanged(),
      rust.PatchAppEvent_ChannelListUpdated() => const ChannelsChanged(),
      // Intentionally not surfaced — no UI consumer reads the per-Peer ack.
      rust.PatchAppEvent_MessageAcked() => null,
    };

PatchChannel _channelFromRust(rust_channel.Channel c) => PatchChannel(
      id: c.id,
      displayName: c.displayName,
      color: _parseHexColor(c.color),
      macros: c.macros.map(_macroFromRust).toList(),
      flashOnCritical: c.flashOnCritical,
      flashOnMessage: c.flashOnMessage,
      flashCount: c.flashCount,
    );

MacroMessage _macroFromRust(rust_channel.MacroMessage s) => MacroMessage(
      label: s.label,
      payload: s.payload,
      keyBinding: s.keyBinding,
      priority: s.priority,
      midiNote: s.midiNote,
      midiCc: s.midiCc,
      osc: s.osc == null ? null : _oscFromRust(s.osc!),
    );

MacroOsc _oscFromRust(rust_channel.OscTarget o) => MacroOsc(
      address: o.address,
      port: o.port,
      path: o.path,
      arg: o.arg,
      argType: switch (o.argType) {
        rust_osc.OscArgKind.string => MacroOscArgType.string,
        rust_osc.OscArgKind.int => MacroOscArgType.int,
        rust_osc.OscArgKind.float => MacroOscArgType.float,
      },
    );

Color _parseHexColor(String hex) =>
    Color(int.parse('FF${hex.replaceFirst('#', '')}', radix: 16));

// Inverse of the three functions above — rebuilds the typed FRB structs from
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

rust_channel.MacroMessage _macroToRust(MacroMessage s) => rust_channel.MacroMessage(
      label: s.label,
      payload: s.payload,
      keyBinding: s.keyBinding,
      priority: s.priority,
      midiNote: s.midiNote,
      midiCc: s.midiCc,
      osc: s.osc == null ? null : _oscToRust(s.osc!),
    );

rust_channel.OscTarget _oscToRust(MacroOsc o) => rust_channel.OscTarget(
      address: o.address,
      port: o.port,
      path: o.path,
      arg: o.arg,
      argType: _toRustArgType(o.argType),
    );

rust_osc.OscArgKind _toRustArgType(MacroOscArgType t) => switch (t) {
      MacroOscArgType.string => rust_osc.OscArgKind.string,
      MacroOscArgType.int => rust_osc.OscArgKind.int,
      MacroOscArgType.float => rust_osc.OscArgKind.float,
    };

PatchMessage _messageFromRust(rust_osc.PatchMessage m) => PatchMessage(
      messageId: m.messageId.toString(),
      senderId: m.senderId.toString(),
      senderName: m.senderName,
      channelId: m.channelId,
      timestamp: m.timestamp,
      priority: m.priority.index,
      payload: m.payload,
    );

PeerInfo _peerFromRust(rust.PeerSnapshot p) => PeerInfo(
      peerId: p.peerId.toString(),
      peerName: p.peerName,
      role: p.role,
      channels: p.channels,
      address: p.address,
      oscPort: p.oscPort,
      lastSeen: p.lastSeen,
      departed: p.departed,
      discoveryMode: switch (p.discoveryMode) {
        rust_peer.DiscoveryMode.mdns => 'mdns',
        rust_peer.DiscoveryMode.oscBeacon => 'osc_beacon',
        rust_peer.DiscoveryMode.manualIp => 'manual_ip',
      },
      status: switch (p.status) {
        rust_peer.PeerStatus.online => PeerStatus.online,
        rust_peer.PeerStatus.stale => PeerStatus.stale,
        rust_peer.PeerStatus.offline => PeerStatus.offline,
      },
    );

StaticPeerInfo _staticPeerFromRust(rust_config.StaticPeer s) => StaticPeerInfo(
      address: s.address,
      port: s.port,
      label: s.label,
    );

ShowFileMeta _showFileMetaFromRust(rust_show_file.ShowFileMeta s) => ShowFileMeta(
      slug: s.slug,
      name: s.name,
      createdAt: s.createdAt,
      channelCount: s.channelCount.toInt(),
    );

AppConfig _configFromRust(rust.ConfigSnapshot cfg) => AppConfig(
      clientName: cfg.clientName,
      role: cfg.role,
      oscPort: cfg.oscPort,
      networkInterface: cfg.networkInterface,
      staticPeers: cfg.staticPeers.map(_staticPeerFromRust).toList(),
      flashOnCritical: cfg.flashOnCritical,
      flashOnMessage: cfg.flashOnMessage,
      flashCount: cfg.flashCount,
      macrosColumns: cfg.macrosColumns,
      hideKeyboard: cfg.hideKeyboard,
      audibleAlert: cfg.audibleAlert,
      globalMacros: cfg.globalMacros.map(_macroFromRust).toList(),
      heartbeatIntervalSecs: cfg.heartbeatIntervalSecs,
      nameIsDefault: cfg.nameIsDefault,
    );

// Keep this import alive — `InterfaceInfo` is referenced only via `rust.`,
// not via the prefix, but the unused-import lint would still trip without it.
// ignore: unused_element
final _keepTransportImport = rust_transport.InterfaceInfo;
