import 'package:flutter/material.dart';
import '../theme/patch_theme.dart';

/// Text input bar at the bottom of each channel view.
/// Enter sends. When [hideKeyboard] is true the field does not auto-focus,
/// preventing the software keyboard from appearing on channel switch.
class MessageInput extends StatefulWidget {
  final ValueChanged<String> onSend;
  final bool hideKeyboard;

  /// Overrides the placeholder text (e.g. a broadcast hint in ALL mode).
  final String? hint;

  const MessageInput({
    super.key,
    required this.onSend,
    this.hideKeyboard = false,
    this.hint,
  });

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
    if (!widget.hideKeyboard) _focus.requestFocus();
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
              decoration: InputDecoration(
                hintText: widget.hint ??
                    (widget.hideKeyboard ? 'Tap to type…' : 'Type a message…'),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              ),
              maxLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _send(),
              autofocus: !widget.hideKeyboard,
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
