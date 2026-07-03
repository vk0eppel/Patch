import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../theme/patch_theme.dart';

/// Opens [assetPath] as a rendered markdown document.
///
/// Call [openHelp] rather than constructing this directly.
class HelpScreen extends StatefulWidget {
  final String assetPath;
  final String title;

  const HelpScreen({super.key, required this.assetPath, required this.title});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  late final Future<String> _content;

  @override
  void initState() {
    super.initState();
    _content = rootBundle.loadString(widget.assetPath);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title.toUpperCase()),
        leading: const BackButton(),
      ),
      body: FutureBuilder<String>(
        future: _content,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Text(
                'Could not load documentation.',
                style: const TextStyle(color: PatchTheme.textMuted),
              ),
            );
          }
          return Markdown(
            data: snap.data!,
            styleSheet: _styleSheet(context),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          );
        },
      ),
    );
  }

  MarkdownStyleSheet _styleSheet(BuildContext context) {
    const body = TextStyle(color: PatchTheme.textPrimary, fontSize: PatchTheme.fontSizeMedium, height: 1.55);
    return MarkdownStyleSheet(
      p: body,
      h1: const TextStyle(color: PatchTheme.textPrimary, fontSize: 22, fontWeight: FontWeight.w700),
      h2: const TextStyle(color: PatchTheme.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
      h3: const TextStyle(color: PatchTheme.textPrimary, fontSize: PatchTheme.fontSizeMedium, fontWeight: FontWeight.w600),
      code: const TextStyle(color: PatchTheme.accent, fontFamily: 'monospace', fontSize: PatchTheme.fontSizeSmall),
      codeblockDecoration: BoxDecoration(
        color: PatchTheme.surfaceHigh,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: PatchTheme.border),
      ),
      blockquoteDecoration: const BoxDecoration(
        border: Border(left: BorderSide(color: PatchTheme.accent, width: 3)),
      ),
      blockquote: const TextStyle(color: PatchTheme.textSecondary, fontSize: PatchTheme.fontSizeMedium),
      tableHead: const TextStyle(color: PatchTheme.textPrimary, fontWeight: FontWeight.w700),
      tableBody: body,
      tableBorder: TableBorder.all(color: PatchTheme.border),
      horizontalRuleDecoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PatchTheme.border)),
      ),
      strong: const TextStyle(color: PatchTheme.textPrimary, fontWeight: FontWeight.w700),
      em: const TextStyle(color: PatchTheme.textPrimary, fontStyle: FontStyle.italic),
      a: const TextStyle(color: PatchTheme.accent),
      listBullet: const TextStyle(color: PatchTheme.textSecondary),
    );
  }
}

/// Navigate to [HelpScreen] displaying [assetPath].
///
/// [assetPath] must match an entry declared in pubspec.yaml assets (e.g.
/// `'assets/docs/networking.md'`).
void openHelp(BuildContext context, {required String assetPath, required String title}) {
  Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => HelpScreen(assetPath: assetPath, title: title),
    ),
  );
}
