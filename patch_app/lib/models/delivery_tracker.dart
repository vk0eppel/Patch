import 'message.dart';

/// Owns delivery status for Critical Messages *we* sent, keyed by message id
/// (only the sender tracks ACKs — see [MessageDeliveryStatus]).
///
/// [clearForMessageIds] exists because a per-channel `messages_cleared` only
/// removes that channel's message list — without it, delivery entries for
/// those message ids would never be removed and would accumulate for the
/// life of the session.
class DeliveryTracker {
  final Map<String, MessageDeliveryStatus> _byId = {};

  Map<String, MessageDeliveryStatus> get all => Map.unmodifiable(_byId);

  MessageDeliveryStatus? statusFor(String messageId) => _byId[messageId];

  void track(String messageId, MessageDeliveryStatus status) {
    _byId[messageId] = status;
  }

  void clearForMessageIds(Iterable<String> messageIds) {
    for (final id in messageIds) {
      _byId.remove(id);
    }
  }

  void clearAll() => _byId.clear();
}
