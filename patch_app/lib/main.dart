import 'package:flutter/material.dart';

import 'bridge/bridge_client.dart';
import 'screens/home_screen.dart';
import 'theme/patch_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const PatchApp());
}

class PatchApp extends StatelessWidget {
  const PatchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PATCH',
      debugShowCheckedModeBanner: false,
      theme: PatchTheme.dark(),
      home: const AppRoot(),
    );
  }
}

class AppRoot extends StatefulWidget {
  const AppRoot({super.key});

  @override
  State<AppRoot> createState() => _AppRootState();
}

class _AppRootState extends State<AppRoot> {
  late final BridgeClient _bridge;
  bool _connected = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _bridge = BridgeClient();
    _connect();
  }

  Future<void> _connect() async {
    setState(() => _error = null);
    try {
      await _bridge.connect();
      if (mounted) setState(() => _connected = true);
    } catch (e) {
      // A failed engine boot (socket bind failure, corrupt patch.toml, denied
      // permission) must not leave the user on an endless spinner.
      if (mounted) setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.redAccent),
                const SizedBox(height: 16),
                const Text(
                  'Could not start the PATCH engine',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }
    if (!_connected) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Connecting to PATCH engine…'),
            ],
          ),
        ),
      );
    }
    return HomeScreen(bridge: _bridge);
  }
}
