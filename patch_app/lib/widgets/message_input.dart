import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/patch_theme.dart';

/// Text input bar at the bottom of each channel view.
/// Enter sends. Shift+Enter inserts a newline (future use).
class MessageInput extends StatefulWidget {
  final ValueChanged<String> onSend;
  const MessageInput({super.key, required this.onSend});

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _ctrl = TextEditingController();
  final _focus = FocusNode();

  void _send() {
    final text = _ctrl.text.trim();
    if (text.isEmpty) return;
    widget.onSend(text);
    _ctrl.clear();
    _focus.requestFocus();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PatchTheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              style: const TextStyle(
                color: PatchTheme.textPrimary,
                fontSize: PatchTheme.fontSizeMedium,
              ),
              decoration: const InputDecoration(
                hintText: 'Type a message…',
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              // Single-line so Enter triggers onSubmitted rather than a newline.
              // maxLines: 1 is required for onSubmitted to fire on desktop.
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              autofocus: true,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            icon: const Icon(Icons.send, color: PatchTheme.accent),
            onPressed: _send,
            tooltip: 'Send (Enter)',
            splashRadius: 20,
          ),
        ],
      ),
    );
  }
}
