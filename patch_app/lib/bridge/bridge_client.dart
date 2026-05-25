import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Connects to the patch-core TCP bridge server and provides
/// a simple command/event interface for the rest of the Flutter app.
///
/// All commands are fire-and-forget JSON lines.
/// Events arrive as a [Stream<Map<String, dynamic>>].
class BridgeClient {
  static const _host = '127.0.0.1';
  static const _port = 9001;
  static const _reconnectDelay = Duration(seconds: 2);

  Socket? _socket;
  final _eventController = StreamController<Map<String, dynamic>>.broadcast();
  bool _disposed = false;

  Stream<Map<String, dynamic>> get events => _eventController.stream;

  /// Connect (and auto-reconnect on disconnect).
  Future<void> connect() async {
    while (!_disposed) {
      try {
        _socket = await Socket.connect(_host, _port);
        _socket!
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              _onLine,
              onDone: _onDisconnect,
              onError: (_) => _onDisconnect(),
            );
        return; // Connected — exit the loop
      } catch (_) {
        await Future.delayed(_reconnectDelay);
      }
    }
  }

  void _onLine(String line) {
    try {
      final map = jsonDecode(line) as Map<String, dynamic>;
      _eventController.add(map);
    } catch (_) {
      // Ignore malformed lines
    }
  }

  void _onDisconnect() {
    _socket = null;
    if (!_disposed) {
      // Reconnect after a short delay
      Future.delayed(_reconnectDelay, connect);
    }
  }

  /// Send a raw command map to the engine.
  void send(Map<String, dynamic> cmd) {
    final line = jsonEncode(cmd) + '\n';
    _socket?.write(line);
  }

  // ── Convenience methods ───────────────────────────────────────────────────

  void sendMessage({
    required String channelId,
    required String payload,
    int priority = 1,
  }) =>
      send({'cmd': 'send_message', 'channel_id': channelId, 'payload': payload, 'priority': priority});

  void sendFlash(String channelId) =>
      send({'cmd': 'send_flash', 'channel_id': channelId});

  void getChannels() => send({'cmd': 'get_channels'});

  void getPeers() => send({'cmd': 'get_peers'});

  void getMessages(String channelId, {int limit = 50}) =>
      send({'cmd': 'get_messages', 'channel_id': channelId, 'limit': limit});

  void getInterfaces() => send({'cmd': 'get_interfaces'});

  void getConfig() => send({'cmd': 'get_config'});

  void setInterface(String name) =>
      send({'cmd': 'set_interface', 'name': name});

  void setClientName(String name) =>
      send({'cmd': 'set_client_name', 'name': name});

  void addStaticPeer(String address, int port, {String? label}) =>
      send({'cmd': 'add_static_peer', 'address': address, 'port': port, 'label': label});

  void upsertChannel(String id, String displayName, String color) =>
      send({'cmd': 'upsert_channel', 'id': id, 'display_name': displayName, 'color': color});

  void upsertShortcut({
    required String channelId,
    required String label,
    required String payload,
    String? keyBinding,
    int priority = 1,
  }) =>
      send({
        'cmd': 'upsert_shortcut',
        'channel_id': channelId,
        'label': label,
        'payload': payload,
        if (keyBinding != null) 'key_binding': keyBinding,
        'priority': priority,
      });

  void deleteShortcut({required String channelId, required String label}) =>
      send({'cmd': 'delete_shortcut', 'channel_id': channelId, 'label': label});

  void deleteChannel(String id) =>
      send({'cmd': 'delete_channel', 'id': id});

  void saveSession(String name) =>
      send({'cmd': 'save_session', 'name': name});

  void loadSession(String slug) =>
      send({'cmd': 'load_session', 'slug': slug});

  void listSessions() =>
      send({'cmd': 'list_sessions'});

  void deleteSession(String slug) =>
      send({'cmd': 'delete_session', 'slug': slug});

  void dispose() {
    _disposed = true;
    _socket?.destroy();
    _eventController.close();
  }
}
