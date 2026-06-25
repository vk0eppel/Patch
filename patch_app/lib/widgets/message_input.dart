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

  /// Optional externally-owned [FocusNode]; if provided the widget does not
  /// dispose it. Allows callers to programmatically refocus the input (e.g.
  /// after a channel switch on desktop) without exposing internal state.
  final FocusNode? focusNode;

  const MessageInput({
    super.key,
    required this.onSend,
    this.hideKeyboard = false,
    this.hint,
    this.focusNode,
  });

  @override
  State<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends State<MessageInput> {
  final _ctrl = TextEditingController();
  // Only created (and disposed) when the caller doesn't supply their own node.
  FocusNode? _ownFocus;

  FocusNode get _focus => widget.focusNode ?? (_ownFocus ??= FocusNode());

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
    _ownFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: PatchTheme.surface,
      height: PatchTheme.footerHeight,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ctrl,
              focusNode: _focus,
              autofocus: !widget.hideKeyboard && widget.focusNode == null,
              style: const TextStyle(
                color: PatchTheme.textPrimary,
                fontSize: PatchTheme.fontSizeMedium,
              ),
              // isDense + textAlignVertical.center: without them the decorator
              // reserves space for a floating label this field doesn't have,
              // pushing the text up instead of centering it in the footer.
              textAlignVertical: TextAlignVertical.center,
              decoration: InputDecoration(
                isDense: true,
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
              // Crew callouts are short codes/jargon, not prose — autocorrect
              // fights that anyway. Disabling both also removes iOS's
              // predictive-text (QuickType) bar above the keys, which is the
              // one real way to shrink the keyboard's footprint; the key rows
              // themselves aren't resizable by an app.
              autocorrect: false,
              enableSuggestions: false,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            // The send glyph's artwork sits low in its own bounding box even
            // though that box is geometrically centered — nudge it up to
            // compensate.
            icon: Transform.translate(
              offset: const Offset(0, -4),
              child: const Icon(Icons.send, color: PatchTheme.accent),
            ),
            onPressed: _send,
            tooltip: 'Send (Enter)',
            splashRadius: 20,
          ),
        ],
      ),
    );
  }
}
