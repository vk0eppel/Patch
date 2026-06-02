import 'package:flutter/material.dart';
import '../models/message.dart';
import '../theme/patch_theme.dart';

class MessageList extends StatefulWidget {
  final List<PatchMessage> messages;

  /// When provided (multi-channel mode), each message row shows a coloured dot
  /// for its channel. Key = channel_id, value = channel colour.
  final Map<String, Color>? channelColors;

  const MessageList({
    super.key,
    required this.messages,
    this.channelColors,
  });

  @override
  State<MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<MessageList> {
  final _scrollCtrl = ScrollController();

  @override
  void didUpdateWidget(covariant MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.messages.length != oldWidget.messages.length) {
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
      ),
    );
  }
}

class _MessageTile extends StatelessWidget {
  final PatchMessage message;

  /// When non-null, a coloured dot is shown to the left of the timestamp.
  final Color? channelColor;

  const _MessageTile({required this.message, this.channelColor});

  Color get _priorityColor {
    return switch (message.priority) {
      3 => PatchTheme.critical,
      2 => PatchTheme.warning,
      _ => Colors.transparent,
    };
  }

  @override
  Widget build(BuildContext context) {
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
            // Channel dot — only shown in multi-channel mode
            if (channelColor != null) ...[
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
            // Sender
            Text(
              message.senderName,
              style: TextStyle(
                color: isCritical ? PatchTheme.critical : PatchTheme.accent,
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
          ],
        ),
      ),
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
