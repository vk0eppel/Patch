import 'package:flutter/material.dart';
import '../models/message.dart';
import '../theme/patch_theme.dart';

class MessageList extends StatefulWidget {
  final List<PatchMessage> messages;

  /// When provided (multi-channel mode), each message row shows a coloured dot
  /// for its channel. Key = channel_id, value = channel colour.
  final Map<String, Color>? channelColors;

  /// Delivery status for criticals we sent, keyed by message id. A row whose id
  /// is present shows a delivery indicator (only our own sent criticals appear).
  final Map<String, MessageDeliveryStatus>? delivery;

  const MessageList({
    super.key,
    required this.messages,
    this.channelColors,
    this.delivery,
  });

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final _scrollCtrl = ScrollController();

  @override
  void didUpdateWidget(covariant MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Scroll when a new message lands at the tail — comparing the tail id rather
    // than the length, because the list is capped (home_screen) so length stays
    // pinned at the cap once full and a length check would stop firing. The
    // length compare still covers clears/session loads (empty↔non-empty).
    final oldLast =
        oldWidget.messages.isNotEmpty ? oldWidget.messages.last.messageId : null;
    final newLast =
        widget.messages.isNotEmpty ? widget.messages.last.messageId : null;
    if (newLast != oldLast ||
        widget.messages.length != oldWidget.messages.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            _scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'Patch',
              style: TextStyle(
                color: PatchTheme.textMuted,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 10),
            Text(
              'No messages yet',
              style: TextStyle(color: PatchTheme.textMuted),
            ),
            SizedBox(height: 6),
            Text(
              'Are you on the same network as your crew?',
              style: TextStyle(color: PatchTheme.textMuted, fontSize: 11),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: widget.messages.length,
      itemBuilder: (ctx, i) => _MessageTile(
        message: widget.messages[i],
        channelColor: widget.channelColors?[widget.messages[i].channelId],
        delivery: widget.delivery?[widget.messages[i].messageId],
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  final PatchMessage message;

  /// When non-null, a coloured dot is shown to the left of the timestamp.
  final Color? channelColor;

  /// When non-null, a delivery indicator is shown at the end of the row.
  final MessageDeliveryStatus? delivery;

  const _MessageTile({required this.message, this.channelColor, this.delivery});

  Color get _priorityColor {
    return switch (message.priority) {
      3 => PatchTheme.critical,
      2 => PatchTheme.warning,
      _ => Colors.transparent,
    };
  }

  String get _flashLabel {
    final name = message.flashSenderName ?? message.senderName;
    final role = message.flashSenderRole;
    return (role != null && role.isNotEmpty) ? '$name ($role) flashed' : '$name flashed';
  }

  @override
  Widget build(BuildContext context) {
    if (message.isFlash) {
      // Mirror the message-row container (margin + 3px border slot + inner
      // padding + optional channel dot) so the timestamp column lines up
      // with every other row — just chrome-less and compact.
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: Colors.transparent, width: 3)),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          child: Row(
            children: [
              if (channelColor != null) ...[
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: channelColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
              Text(
                _formatTime(message.timestamp),
                style: const TextStyle(
                  color: PatchTheme.textMuted,
                  fontSize: PatchTheme.fontSizeSmall,
                  fontFamily: 'monospace',
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _flashLabel,
                style: const TextStyle(
                  color: PatchTheme.textMuted,
                  fontSize: PatchTheme.fontSizeSmall,
                ),
              ),
            ],
          ),
        ),
      );
    }

    final isCritical = message.isCritical;
    final isWarning = message.isWarning;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      decoration: BoxDecoration(
        color: isCritical
            ? PatchTheme.critical.withAlpha(25)
            : isWarning
                ? PatchTheme.warning.withAlpha(15)
                : Colors.transparent,
        borderRadius: BorderRadius.circular(4),
        border: Border(left: BorderSide(color: _priorityColor, width: 3)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Broadcast marker (📢) for ALL-channel messages, else the channel
            // dot in multi-channel / ALL views.
            if (message.channelId == kAllChannelId) ...[
              const Padding(
                padding: EdgeInsets.only(top: 2, right: 6),
                child: Text('📢', style: TextStyle(fontSize: 11)),
              ),
            ] else if (channelColor != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 6),
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: channelColor,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ],
            // Timestamp
            Text(
              _formatTime(message.timestamp),
              style: const TextStyle(
                color: PatchTheme.textMuted,
                fontSize: PatchTheme.fontSizeSmall,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(width: 10),
            // Sender — coloured by priority so the level reads from the name
            // alone: critical red, warning amber, info blue.
            Text(
              message.senderName,
              style: TextStyle(
                color: isCritical
                    ? PatchTheme.critical
                    : isWarning
                        ? PatchTheme.warning
                        : PatchTheme.accent,
                fontSize: PatchTheme.fontSizeSmall,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 8),
            // Payload
            Expanded(
              child: Text(
                message.payload,
                style: TextStyle(
                  color: isCritical ? PatchTheme.critical : PatchTheme.textPrimary,
                  fontSize: PatchTheme.fontSizeMedium,
                  fontWeight: isCritical ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ),
            // Delivery indicator (sender-side, criticals only)
            if (delivery != null) _deliveryBadge(delivery!),
          ],
        ),
      ),
    );
  }

  /// A small trailing indicator for the delivery state of a critical we sent:
  /// a red ⚠ if it wasn't received, a green ✓ once every peer has it, or an
  /// amber "N/M" while it's still being delivered/retried.
  Widget _deliveryBadge(MessageDeliveryStatus d) {
    final Widget child;
    final String tip;
    if (d.failed) {
      tip = d.total == 0
          ? 'No peers online — not delivered'
          : d.failedPeers.isNotEmpty
              ? 'Not delivered to: ${d.failedPeers.join(', ')}'
              : 'Not delivered to all peers';
      child = const Icon(Icons.error_outline, size: 14, color: PatchTheme.critical);
    } else if (d.isComplete) {
      tip = 'Delivered to all ${d.total}';
      child = const Icon(Icons.done_all, size: 14, color: PatchTheme.success);
    } else {
      tip = 'Delivered to ${d.delivered} of ${d.total}';
      child = Text(
        '${d.delivered}/${d.total}',
        style: const TextStyle(
          color: PatchTheme.warning,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(left: 6, top: 2),
      child: Tooltip(message: tip, child: child),
    );
  }

  String _formatTime(DateTime dt) {
    final local = dt.toLocal();
    final h = local.hour.toString().padLeft(2, '0');
    final m = local.minute.toString().padLeft(2, '0');
    final s = local.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}
