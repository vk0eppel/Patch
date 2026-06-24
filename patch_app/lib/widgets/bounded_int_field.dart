import 'package:flutter/material.dart';
import '../theme/patch_theme.dart';

/// Compact numeric field constrained to [min]..[max] (inclusive).
///
/// Validates on submit: an out-of-range or non-numeric entry shows the range as
/// an inline error and does **not** call [onSubmit], so the engine is never
/// handed a bad value. Seeded from [value]; key the widget by the value so an
/// external config refresh reseeds the field. Used for the Settings → Network
/// numeric settings (heartbeat interval, OSC port).
class BoundedIntField extends StatefulWidget {
  final int value;
  final int min;
  final int max;

  /// Optional unit shown inside the field (e.g. 's' for seconds). Null = none.
  final String? suffix;
  final ValueChanged<int> onSubmit;

  const BoundedIntField({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onSubmit,
    this.suffix,
  });

  @override
  State<BoundedIntField> createState() => _BoundedIntFieldState();
}

class _BoundedIntFieldState extends State<BoundedIntField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value.toString());
  late final FocusNode _focusNode = FocusNode()..addListener(_onFocusChange);
  String? _error;
  // TextField's default behavior unfocuses after onSubmitted fires, which
  // would otherwise double-fire _submit via _onFocusChange for the same
  // value — track the last committed text to skip that redundant call.
  late String _lastCommitted = widget.value.toString();

  @override
  void dispose() {
    _focusNode.removeListener(_onFocusChange);
    _focusNode.dispose();
    _ctrl.dispose();
    super.dispose();
  }

  // Crew members move on to the next field without pressing Enter — commit
  // on focus-loss too, so an edit isn't silently dropped (#71).
  void _onFocusChange() {
    if (!_focusNode.hasFocus) _submit();
  }

  void _submit() {
    final text = _ctrl.text.trim();
    if (text == _lastCommitted) return;
    final n = int.tryParse(text);
    if (n == null || n < widget.min || n > widget.max) {
      setState(() => _error = '${widget.min}–${widget.max}');
      return;
    }
    setState(() => _error = null);
    _lastCommitted = text;
    widget.onSubmit(n);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 112,
      child: TextField(
        controller: _ctrl,
        focusNode: _focusNode,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: PatchTheme.textPrimary,
          fontSize: PatchTheme.fontSizeMedium,
        ),
        decoration: InputDecoration(
          isDense: true,
          suffixText: widget.suffix,
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
    );
  }
}
