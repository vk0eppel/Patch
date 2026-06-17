import 'package:flutter/material.dart';
import '../theme/patch_theme.dart';

/// Compact numeric field for the presence heartbeat interval (1–60 s).
///
/// Validates on submit: an out-of-range or non-numeric entry shows an inline
/// error and does **not** call [onSubmit], so the engine is never handed a bad
/// value. Seeded from [value]; key the widget by the value so an external config
/// refresh reseeds the field.
class HeartbeatField extends StatefulWidget {
  final int value;
  final ValueChanged<int> onSubmit;
  const HeartbeatField({super.key, required this.value, required this.onSubmit});

  @override
  State<HeartbeatField> createState() => _HeartbeatFieldState();
}

class _HeartbeatFieldState extends State<HeartbeatField> {
  late final TextEditingController _ctrl =
      TextEditingController(text: widget.value.toString());
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final secs = int.tryParse(_ctrl.text.trim());
    if (secs == null || secs < 1 || secs > 60) {
      setState(() => _error = '1–60');
      return;
    }
    setState(() => _error = null);
    widget.onSubmit(secs);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
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
          suffixText: 's',
          errorText: _error,
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (_) => _submit(),
      ),
    );
  }
}
