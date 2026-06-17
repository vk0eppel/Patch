import 'dart:async';

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
  StreamSubscription<rust.PatchAppEvent>? _engineSub;
  bool _connected = false;

  /// `RustLib.init()` may only be called once per process — FRB throws on a
  /// second call. Tracked separately from [_connected] so a retry after a
  /// failed `rust.init()` (e.g. socket bind error) doesn't re-init the lib.
  static bool _rustLibInitialized = false;

  /// Stream of legacy-shaped events: `{"event": "<type>", ...}`.
  Stream<Map<String, dynamic>> get events => _eventController.stream;

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

  void _forwardEngineEvent(rust.PatchAppEvent event) {
    final map = switch (event) {
      rust.PatchAppEvent_Message(:final field0) => {
        'event': 'message',
        'data': _messageToMap(field0),
      },
      rust.PatchAppEvent_MessageAcked(:final messageId, :final peerId) => {
        'event': 'message_acked',
        'message_id': messageId,
        'peer_id': peerId,
      },
      rust.PatchAppEvent_MessageDelivery(
        :final messageId,
        :final delivered,
        :final total,
        :final failed,
        :final failedPeers,
      ) => {
        'event': 'message_delivery',
        'message_id': messageId,
        'delivered': delivered,
        'total': total,
        'failed': failed,
        'failed_peers': failedPeers,
      },
      rust.PatchAppEvent_PeerUpdated(:final field0) => {
        'event': 'peer_updated',
        'data': _presenceToPeerMap(field0),
      },
      rust.PatchAppEvent_PeerExpired(:final peerId) => {
        'event': 'peer_expired',
        'data': {'peer_id': peerId},
      },
      rust.PatchAppEvent_ChannelFlash(:final field0) => {
        'event': 'channel_flash',
        'data': {
          'channel_id': field0.channelId,
          'sender_id': field0.senderId.toString(),
          'sender_name': field0.senderName,
        },
      },
      rust.PatchAppEvent_ChannelListUpdated() => {
        'event': 'channel_list_updated',
      },
      rust.PatchAppEvent_ChannelsOffered(
        :final fromPeerId,
        :final fromName,
        :final channels,
      ) => {
        'event': 'channels_offered',
        'from_peer_id': fromPeerId,
        'from_name': fromName,
        'channels': channels.map(_channelToMap).toList(),
      },
      rust.PatchAppEvent_ClientNameChanged(:final name) => {
        'event': 'client_name_changed',
        'name': name,
      },
      rust.PatchAppEvent_PermissionDenied(:final context) => {
        'event': 'permission_denied',
        'message': context,
      },
    };
    _eventController.add(map);
  }

  void _emit(Map<String, dynamic> event) => _eventController.add(event);

  void _emitError(Object e) =>
      _emit({'event': 'error', 'message': e.toString()});

  // ── Commands (legacy fire-and-forget shape) ──────────────────────────────

  Future<void> sendMessage({
    required String channelId,
    required String payload,
    int priority = 1,
  }) async {
    try {
      final id = await rust.sendMessage(
        channelId: channelId,
        payload: payload,
        priority: priority,
      );
      _emit({'event': 'ack_send', 'message_id': id});
    } catch (e) {
      _emitError(e);
    }
  }

  /// Send a direct (peer-to-peer) message to one peer. Stored locally under a
  /// `dm:<peerId>` key and unicast only to that peer.
  Future<void> sendDirectMessage({
    required String peerId,
    required String payload,
    int priority = 1,
  }) async {
    try {
      final id = await rust.sendDirectMessage(
        peerId: peerId,
        payload: payload,
        priority: priority,
      );
      _emit({'event': 'ack_send', 'message_id': id});
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> sendFlash(String channelId) async {
    try {
      await rust.sendFlash(channelId: channelId);
    } catch (e) {
      _emitError(e);
    }
  }

  /// Send a direct flash (attention ping) to one peer — unicast only; flashes
  /// the recipient's DM thread with us (and our own thread locally).
  Future<void> sendDmFlash(String peerId) async {
    try {
      await rust.sendDmFlash(peerId: peerId);
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> getChannels() async {
    try {
      final channels = await rust.getChannels();
      _emit({
        'event': 'channels',
        'data': channels.map(_channelToMap).toList(),
      });
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> getPeers() async {
    try {
      final peers = await rust.getPeers();
      _emit({'event': 'peers', 'data': peers.map(_peerToMap).toList()});
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
        'data': messages.map(_messageToMap).toList(),
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
      _emit({
        'event': 'config',
        'data': {
          'client_name': cfg.clientName,
          'role': cfg.role,
          'osc_port': cfg.oscPort,
          'network_interface': cfg.networkInterface,
          'static_peers': cfg.staticPeers.map(_staticPeerToMap).toList(),
          'flash_on_critical': cfg.flashOnCritical,
          'flash_on_message': cfg.flashOnMessage,
          'flash_count': cfg.flashCount,
          'macros_columns': cfg.macrosColumns,
          'hide_keyboard': cfg.hideKeyboard,
          'audible_alert': cfg.audibleAlert,
          'global_macros': cfg.globalMacros.map(_macroToMap).toList(),
          'heartbeat_interval_secs': cfg.heartbeatIntervalSecs,
          'name_is_default': cfg.nameIsDefault,
        },
      });
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> setInterface(String name) async {
    try {
      await rust.setInterface(name: name.isEmpty ? null : name);
      // No restart needed: the socket always binds 0.0.0.0; the NIC only scopes
      // the discovery broadcast, which the engine re-reads each heartbeat.
      _emit({
        'event': 'interface_changed',
        'name': name.isEmpty ? 'auto' : name,
        'restart_required': false,
      });
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> setClientName(String name) async {
    try {
      await rust.setClientName(name: name);
      // `client_name_changed` is also emitted by the engine event bus.
    } catch (e) {
      _emitError(e);
    }
  }

  /// Set (or clear) the self-assigned role. Pass null/empty to clear it.
  Future<void> setRole(String? role) async {
    try {
      final trimmed = role?.trim();
      await rust.setRole(
        role: (trimmed == null || trimmed.isEmpty) ? null : trimmed,
      );
      await getConfig();
    } catch (e) {
      _emitError(e);
    }
  }

  /// Remove dynamic peers (OscBeacon / Mdns) not heard from within [maxAgeSecs].
  /// ManualIp / static peers are never removed.
  Future<void> clearStalePeers({int maxAgeSecs = 60}) async {
    try {
      await rust.clearStalePeers(maxAgeSecs: BigInt.from(maxAgeSecs));
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> addStaticPeer(String address, int port, {String? label}) async {
    try {
      await rust.addStaticPeer(address: address, port: port, label: label);
      _emit({'event': 'config_updated'});
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> removeStaticPeer(String address, int port) async {
    try {
      await rust.removeStaticPeer(address: address, port: port);
      _emit({'event': 'config_updated'});
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> upsertChannel(
    String id,
    String displayName,
    String color,
  ) async {
    try {
      await rust.upsertChannel(
        id: id,
        displayName: displayName,
        color: color,
      );
    } catch (e) {
      _emitError(e);
    }
  }

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
  }) async {
    try {
      await rust.upsertMacro(
        channelId: channelId,
        label: label,
        payload: payload,
        priority: priority,
        keyBinding: keyBinding,
        midiNote: midiNote,
        midiCc: midiCc,
        osc: _buildOsc(oscAddress, oscPort, oscPath, oscArg),
      );
    } catch (e) {
      _emitError(e);
    }
  }

  /// Fire an arbitrary OSC message to external gear (the dual-action half of an
  /// OSC macro — the Patch message is sent separately via [sendMessage]).
  Future<void> sendOscMacro(String address, int port, String path, String? arg) async {
    try {
      await rust.sendOscMacro(address: address, port: port, path: path, arg: arg);
    } catch (e) {
      _emitError(e);
    }
  }

  /// Names of available MIDI input ports (for a future port-selector UI).
  Future<List<String>> getMidiPorts() async {
    try {
      return await rust.getMidiPorts();
    } catch (e) {
      _emitError(e);
      return const [];
    }
  }

  Future<void> deleteMacro({
    required String channelId,
    required String label,
  }) async {
    try {
      await rust.deleteMacro(channelId: channelId, label: label);
    } catch (e) {
      _emitError(e);
    }
  }

  /// Reorder a channel's macros to match [labels] (drag-to-reorder).
  Future<void> reorderMacros(String channelId, List<String> labels) async {
    try {
      await rust.reorderMacros(channelId: channelId, orderedLabels: labels);
    } catch (e) {
      _emitError(e);
    }
  }

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
  }) async {
    try {
      await rust.upsertGlobalMacro(
        label: label,
        payload: payload,
        priority: priority,
        keyBinding: keyBinding,
        midiNote: midiNote,
        midiCc: midiCc,
        osc: _buildOsc(oscAddress, oscPort, oscPath, oscArg),
      );
      _emit({'event': 'config_updated'});
    } catch (e) {
      _emitError(e);
    }
  }

  /// Build a typed `OscTarget` from flat UI fields — null unless address, port,
  /// and path are all present (an empty `arg` collapses to null).
  rust_channel.OscTarget? _buildOsc(
    String? address,
    int? port,
    String? path,
    String? arg,
  ) {
    if (address == null || address.isEmpty || port == null || path == null || path.isEmpty) {
      return null;
    }
    return rust_channel.OscTarget(
      address: address,
      port: port,
      path: path,
      arg: (arg == null || arg.isEmpty) ? null : arg,
    );
  }

  /// Push the UI's current channel selection to the engine so a MIDI-triggered
  /// global macro fires on the same channel(s) as a tap/F-key. Fire-and-forget.
  Future<void> setSelectedChannels(List<String> ids) async {
    try {
      await rust.setSelectedChannels(ids: ids);
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> deleteGlobalMacro(String label) async {
    try {
      await rust.deleteGlobalMacro(label: label);
      _emit({'event': 'config_updated'});
    } catch (e) {
      _emitError(e);
    }
  }

  /// Restore the factory default global macros (replaces the current set).
  Future<void> resetGlobalMacros() async {
    try {
      await rust.resetGlobalMacros();
      _emit({'event': 'config_updated'});
    } catch (e) {
      _emitError(e);
    }
  }

  /// Reorder global macros to match [labels] (drag-to-reorder).
  Future<void> reorderGlobalMacros(List<String> labels) async {
    try {
      await rust.reorderGlobalMacros(orderedLabels: labels);
      _emit({'event': 'config_updated'});
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> deleteChannel(String id) async {
    try {
      await rust.deleteChannel(id: id);
    } catch (e) {
      _emitError(e);
    }
  }

  /// Export messages to a CSV file at [path].
  /// Pass [channelId] to export a single channel, or null for all channels.
  Future<void> exportMessages({String? channelId, required String path}) async {
    try {
      await rust.exportMessages(channelId: channelId, path: path);
    } catch (e) {
      _emitError(e);
    }
  }

  /// Clear messages for [channelId], or all channels when null.
  Future<void> clearMessages({String? channelId}) async {
    try {
      await rust.clearMessages(channelId: channelId);
      _emit({'event': 'messages_cleared', 'channel_id': channelId});
    } catch (e) {
      _emitError(e);
    }
  }

  /// Ask a peer (by id) for its channel layout. The reply arrives asynchronously
  /// as a `channels_offered` event (not auto-applied — the UI previews + merges).
  Future<void> requestChannels(String peerId) async {
    try {
      await rust.requestChannels(peerId: peerId);
    } catch (e) {
      _emitError(e);
    }
  }

  /// Adopt offered channels — merge (adds only ids not already present). Takes
  /// the legacy channel-map shape (as delivered in `channels_offered`) and
  /// rebuilds the typed FRB `Channel`s. Emits `channels_adopted` with the count.
  Future<void> adoptChannels(List<Map<String, dynamic>> channels) async {
    try {
      final rebuilt = channels.map(_channelFromMap).toList();
      final added = await rust.adoptChannels(channels: rebuilt);
      _emit({'event': 'channels_adopted', 'added': added});
    } catch (e) {
      _emitError(e);
    }
  }

  /// Reset all channels to factory defaults (AUDIO · RF · LIGHTING · VIDEO · STAGE).
  Future<void> resetChannels() async {
    try {
      await rust.resetChannels();
      // ChannelListUpdated is emitted by the engine; home_screen will refresh.
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> saveShowFile(String name) async {
    try {
      final s = await rust.saveShowFile(name: name);
      _emit({'event': 'show_file_saved', 'slug': s.slug, 'name': s.name});
    } catch (e) {
      _emitError(e);
    }
  }

  /// Export the current layout to an arbitrary file path (from a file picker).
  Future<void> exportLayout(String path, {String name = ''}) async {
    try {
      await rust.exportLayout(path: path, name: name);
    } catch (e) {
      _emitError(e);
    }
  }

  /// Import a show file from an arbitrary file path (from a file picker) and apply it.
  Future<void> importLayout(String path) async {
    try {
      final s = await rust.importLayout(path: path);
      _emit({'event': 'show_file_loaded', 'slug': s.slug, 'name': s.name, 'channel_count': s.channelCount});
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> loadShowFile(String slug) async {
    try {
      final s = await rust.loadShowFile(slug: slug);
      _emit({
        'event': 'show_file_loaded',
        'slug': s.slug,
        'name': s.name,
        'channel_count': s.channelCount,
      });
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> listShowFiles() async {
    try {
      final list = await rust.listShowFiles();
      _emit({
        'event': 'show_files',
        'data': list.map(_showFileMetaToMap).toList(),
      });
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> deleteShowFile(String slug) async {
    try {
      await rust.deleteShowFile(slug: slug);
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> setFlashOnCritical(bool enabled) async {
    try {
      await rust.setFlashOnCritical(enabled: enabled);
      _emit({'event': 'config_updated', 'flash_on_critical': enabled});
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> setFlashOnMessage(bool enabled) async {
    try {
      await rust.setFlashOnMessage(enabled: enabled);
      _emit({'event': 'config_updated', 'flash_on_message': enabled});
    } catch (e) {
      _emitError(e);
    }
  }

  /// Set the global flash pulse count (3–7).
  Future<void> setFlashCount(int count) async {
    try {
      await rust.setFlashCount(count: count);
      _emit({'event': 'config_updated', 'flash_count': count});
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> setHideKeyboard(bool enabled) async {
    try {
      await rust.setHideKeyboard(enabled: enabled);
      await getConfig();
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> setAudibleAlert(bool enabled) async {
    try {
      await rust.setAudibleAlert(enabled: enabled);
      await getConfig();
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> setMacrosColumns(int columns) async {
    try {
      await rust.setMacrosColumns(columns: columns);
      await getConfig();
    } catch (e) {
      _emitError(e);
    }
  }

  Future<void> setChannelFlash(
    String channelId, {
    bool? flashOnCritical,
    bool? flashOnMessage,
    /// Pass 0 to clear the per-channel override (revert to global).
    int? flashCount,
  }) async {
    try {
      await rust.setChannelFlash(
        channelId: channelId,
        flashOnCritical: flashOnCritical,
        flashOnMessage: flashOnMessage,
        flashCount: flashCount,
      );
    } catch (e) {
      _emitError(e);
    }
  }

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
  }
}

// ── Conversion helpers ──────────────────────────────────────────────────────
//
// The Dart models (PatchMessage.fromJson, PatchChannel.fromJson, ...) expect
// snake_case keys, ISO-8601 timestamp strings, UUIDs-as-strings, and integer
// priorities. The FRB-generated types are strongly-typed Dart classes with
// DateTime/UuidValue/enum fields — we re-emit them in the legacy JSON shape
// so the screens keep working unchanged.

Map<String, dynamic> _channelToMap(rust_channel.Channel c) => {
      'id': c.id,
      'display_name': c.displayName,
      'color': c.color,
      'macros': c.macros.map(_macroToMap).toList(),
      'flash_on_critical': c.flashOnCritical,
      'flash_on_message': c.flashOnMessage,
      'flash_count': c.flashCount,
    };

Map<String, dynamic> _macroToMap(rust_channel.MacroMessage s) => {
      'label': s.label,
      'payload': s.payload,
      'key_binding': s.keyBinding,
      'priority': s.priority,
      'midi_note': s.midiNote,
      'midi_cc': s.midiCc,
      'osc': s.osc == null
          ? null
          : {
              'address': s.osc!.address,
              'port': s.osc!.port,
              'path': s.osc!.path,
              'arg': s.osc!.arg,
            },
    };

// Inverse of `_channelToMap`/`_macroToMap` — rebuilds the typed FRB structs from
// the legacy map shape so offered channels (delivered as maps) can be passed back
// into `adopt_channels`.
rust_channel.Channel _channelFromMap(Map<String, dynamic> m) => rust_channel.Channel(
      id: m['id'] as String,
      displayName: m['display_name'] as String,
      color: m['color'] as String,
      macros: ((m['macros'] as List<dynamic>?) ?? const [])
          .map((e) => _macroFromMap(e as Map<String, dynamic>))
          .toList(),
      flashOnCritical: m['flash_on_critical'] as bool? ?? true,
      flashOnMessage: m['flash_on_message'] as bool? ?? false,
      flashCount: m['flash_count'] as int?,
    );

rust_channel.MacroMessage _macroFromMap(Map<String, dynamic> m) => rust_channel.MacroMessage(
      label: m['label'] as String,
      payload: m['payload'] as String,
      keyBinding: m['key_binding'] as String?,
      priority: (m['priority'] as num).toInt(),
      midiNote: (m['midi_note'] as num?)?.toInt(),
      midiCc: (m['midi_cc'] as num?)?.toInt(),
      osc: _oscFromMap(m['osc']),
    );

rust_channel.OscTarget? _oscFromMap(dynamic o) {
  if (o == null) return null;
  final m = Map<String, dynamic>.from(o as Map);
  return rust_channel.OscTarget(
    address: m['address'] as String,
    port: (m['port'] as num).toInt(),
    path: m['path'] as String,
    arg: m['arg'] as String?,
  );
}

Map<String, dynamic> _messageToMap(rust_osc.PatchMessage m) => {
      'message_id': m.messageId.toString(),
      'sender_id': m.senderId.toString(),
      'sender_name': m.senderName,
      'channel_id': m.channelId,
      'timestamp': m.timestamp.toIso8601String(),
      'priority': m.priority.index,
      'payload': m.payload,
    };

Map<String, dynamic> _peerToMap(rust_peer.Peer p) => {
      'peer_id': p.peerId.toString(),
      'peer_name': p.peerName,
      'role': p.role,
      'channels': p.channels,
      'address': p.address,
      'osc_port': p.oscPort,
      'last_seen': p.lastSeen.toIso8601String(),
      'discovery_mode': switch (p.discoveryMode) {
        rust_peer.DiscoveryMode.mdns => 'mdns',
        rust_peer.DiscoveryMode.oscBeacon => 'osc_beacon',
        rust_peer.DiscoveryMode.manualIp => 'manual_ip',
      },
    };

/// Map a `PeerPresence` event (broadcast on update) to the legacy `Peer` shape
/// the UI expects. Address/port/last_seen aren't on the presence packet itself;
/// the UI also receives a full `peers` snapshot via `getPeers()` so this is
/// mostly used for the "new peer joined" indicator.
Map<String, dynamic> _presenceToPeerMap(rust_osc.PeerPresence p) => {
      'peer_id': p.peerId.toString(),
      'peer_name': p.peerName,
      'role': p.role,
      'channels': p.channels,
      'address': '',
      'osc_port': 0,
      'last_seen': p.timestamp.toIso8601String(),
      'discovery_mode': 'osc_beacon',
    };

Map<String, dynamic> _staticPeerToMap(rust_config.StaticPeer s) => {
      'address': s.address,
      'port': s.port,
      'label': s.label,
    };

Map<String, dynamic> _showFileMetaToMap(rust_show_file.ShowFileMeta s) => {
      'slug': s.slug,
      'name': s.name,
      'created_at': s.createdAt.toIso8601String(),
      'channel_count': s.channelCount.toInt(),
    };

// Keep this import alive — `InterfaceInfo` is referenced only via `rust.`,
// not via the prefix, but the unused-import lint would still trip without it.
// ignore: unused_element
final _keepTransportImport = rust_transport.InterfaceInfo;
