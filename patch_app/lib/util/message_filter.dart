import '../models/message.dart';

/// Pure message-feed filtering for the in-channel search. Kept free of any widget
/// so the matching rules are unit-testable on their own.
///
/// The three Operator-facing priority levels map from [PatchMessage.priority]:
/// critical (≥3), warning (2), info (≤1, incl. the internal debug level).
String messageCategory(int priority) {
  if (priority >= 3) return 'critical';
  if (priority == 2) return 'warning';
  return 'info';
}

/// Case-insensitive substring match on sender name OR payload. An empty query
/// matches everything.
bool messageMatchesQuery(PatchMessage m, String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return m.senderName.toLowerCase().contains(q) ||
      m.payload.toLowerCase().contains(q);
}

/// Matches when the message's category is one of [categories]. An empty set
/// matches everything (no priority filter active).
bool messageMatchesPriority(PatchMessage m, Set<String> categories) =>
    categories.isEmpty || categories.contains(messageCategory(m.priority));

/// Filter [messages] by a text [query] (sender or payload) AND a priority
/// [categories] set. Both constraints apply; either being empty is a no-op.
List<PatchMessage> filterMessages(
  List<PatchMessage> messages, {
  String query = '',
  Set<String> categories = const {},
}) => messages
    .where(
      (m) =>
          messageMatchesQuery(m, query) &&
          messageMatchesPriority(m, categories),
    )
    .toList();
