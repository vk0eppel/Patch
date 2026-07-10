// The one fake bridge adapter for tests (#188) — the second adapter at the
// command seam #177 built (FFI in production, this in tests).
//
// Built on `Fake implements BridgeClient`, so any bridge method a test
// exercises that isn't stubbed here fails loudly with UnimplementedError
// instead of silently inheriting a live FFI-calling implementation. Reads
// return settable values with call counters; the commonly-spied commands
// record their arguments. Per-test subclasses override only their slice.

import 'dart:async';

import 'package:flutter/material.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:patch/bridge/bridge_client.dart';
import 'package:patch/models/channel.dart';
import 'package:patch/models/config.dart';
import 'package:patch/models/events.dart';
import 'package:patch/models/message.dart';

class FakeBridge extends Fake implements BridgeClient {
  /// Synchronous so a pushed event is reduced before the next test line runs.
  final _pushController = StreamController<PatchEvent>.broadcast(sync: true);

  @override
  Stream<PatchEvent> get pushes => _pushController.stream;

  /// Emit an engine push into every listener, as the engine would.
  void push(PatchEvent event) => _pushController.add(event);

  // ── Settable reads ────────────────────────────────────────────────────

  List<PeerInfo> peersToReturn = const [];
  AppConfig configToReturn = cfg();
  List<PatchChannel> channelsToReturn = const [];
  Map<String, List<PatchMessage>> messagesToReturn = {};
  List<ShowFileMeta> showFilesToReturn = const [];
  List<({String name, String ip})> interfacesToReturn = const [];

  int getPeersCalls = 0;
  int getConfigCalls = 0;
  int getChannelsCalls = 0;
  int getMessagesCalls = 0;

  /// When set, [getMessages] waits on it before returning — lets a test
  /// interleave a push while a fetch is in flight.
  Completer<void>? gateMessages;

  @override
  Future<List<PeerInfo>> getPeers() async {
    getPeersCalls++;
    return peersToReturn;
  }

  @override
  Future<AppConfig> getConfig() async {
    getConfigCalls++;
    return configToReturn;
  }

  @override
  Future<List<PatchChannel>> getChannels() async {
    getChannelsCalls++;
    return channelsToReturn;
  }

  @override
  Future<List<PatchMessage>> getMessages(String channelId,
      {int limit = 500}) async {
    getMessagesCalls++;
    if (gateMessages != null) await gateMessages!.future;
    return messagesToReturn[channelId] ?? const [];
  }

  @override
  Future<List<({String name, String ip})>> getInterfaces() async =>
      interfacesToReturn;

  @override
  Future<List<ShowFileMeta>> listShowFiles() async => showFilesToReturn;

  // ── Recorded commands ─────────────────────────────────────────────────

  final List<List<String>> selectedChannelsCalls = [];
  final List<String?> dmTargetCalls = [];
  final List<String> requestedChannelsFrom = [];
  final List<String> requestedGlobalMacrosFrom = [];
  final List<String> deletedShowFileSlugs = [];

  @override
  Future<void> setSelectedChannels(List<String> ids) async {
    selectedChannelsCalls.add(List.unmodifiable(ids));
  }

  @override
  Future<void> setDmTarget(String? peerId) async {
    dmTargetCalls.add(peerId);
  }

  @override
  Future<void> requestChannels({required String peerId}) async {
    requestedChannelsFrom.add(peerId);
  }

  @override
  Future<void> requestGlobalMacros({required String peerId}) async {
    requestedGlobalMacrosFrom.add(peerId);
  }

  @override
  Future<void> deleteShowFile({required String slug}) async {
    deletedShowFileSlugs.add(slug);
  }
}

// ── Shared fixture builders ─────────────────────────────────────────────

PatchChannel chan(String id) => PatchChannel(
    id: id, displayName: id.toUpperCase(), color: const Color(0xFF1E88E5));

PatchMessage msg(String channelId, String id) => PatchMessage(
      messageId: id,
      senderId: 's',
      senderName: 'S',
      channelId: channelId,
      timestamp: DateTime.utc(2026, 6, 22),
      priority: 1,
      payload: 'hi',
    );

AppConfig cfg({String clientName = 'Me', bool nameIsDefault = false}) =>
    AppConfig(
      clientName: clientName,
      oscPort: 9000,
      flashOnCritical: true,
      flashOnMessage: false,
      flashCount: 4,
      macrosColumns: 1,
      hideKeyboard: true,
      audibleAlert: false,
      heartbeatIntervalSecs: 7,
      nameIsDefault: nameIsDefault,
    );

PeerInfo peerInfo(String id, {String peerName = ''}) => PeerInfo(
      peerId: id,
      peerName: peerName.isEmpty ? 'peer-$id' : peerName,
      channels: const [],
      address: '10.0.0.1',
      oscPort: 9000,
      lastSeen: DateTime.utc(2026, 6, 22),
      discoveryMode: 'osc_beacon',
      status: PeerStatus.online,
    );
