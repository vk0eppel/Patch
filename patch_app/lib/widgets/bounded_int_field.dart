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
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final n = int.tryParse(_ctrl.text.trim());
    if (n == null || n < widget.min || n > widget.max) {
      setState(() => _error = '${widget.min}–${widget.max}');
      return;
    }
    setState(() => _error = null);
    widget.onSubmit(n);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 112,
      child: TextField(
        controller: _ctrl,
        keyboardType: TextInputType.number,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: PatchTheme.textPrimary,
          fontSize: PatchTheme.fontSizeSmall,
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
