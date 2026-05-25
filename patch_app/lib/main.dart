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

  @override
  void initState() {
    super.initState();
    _bridge = BridgeClient();
    _connect();
  }

  Future<void> _connect() async {
    await _bridge.connect();
    setState(() => _connected = true);
  }

  @override
  void dispose() {
    _bridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
