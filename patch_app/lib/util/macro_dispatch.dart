import '../models/message.dart' show kAllChannelId;
import '../models/selection.dart';
import '../widgets/macros_panel.dart' show ChannelMacro;

sealed class MacroTarget {
  const MacroTarget();
}

class ChannelTarget extends MacroTarget {
  final List<String> channelIds;
  const ChannelTarget(this.channelIds);
}

class DmTarget extends MacroTarget {
  final String peerId;
  const DmTarget(this.peerId);
}

/// Routes a macro to its send target given the current selection.
///
/// DM mode takes priority — any macro fired while a DM thread is open goes to
/// that peer. For global macros (empty [ChannelMacro.channelId]), the target
/// follows the selection; for per-channel macros it is always the macro's own
/// channel. Bridge calls and OSC dual-action stay in the caller.
MacroTarget resolveMacroTarget(ChannelMacro macro, Selection selection) {
  if (selection is DmSelection) {
    return DmTarget(selection.peerId);
  }
  if (macro.channelId.isEmpty) {
    return switch (selection) {
      AllSelection() => ChannelTarget([kAllChannelId]),
      ChannelSelection(ids: final ids) => ChannelTarget(ids.toList()),
      DmSelection() => ChannelTarget([]), // unreachable: DmSelection handled above
    };
  }
  return ChannelTarget([macro.channelId]);
}
