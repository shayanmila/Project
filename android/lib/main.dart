import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:local_auth/local_auth.dart';

void main() => runApp(const TradeApp());

class TradeApp extends StatefulWidget {
  const TradeApp({super.key});
  @override
  State<TradeApp> createState() => _TradeAppState();
}

class _TradeAppState extends State<TradeApp> with WidgetsBindingObserver {
  final store = const FlutterSecureStorage();
  final biometric = LocalAuthentication();
  final url = TextEditingController();
  final token = TextEditingController();
  final pin = TextEditingController();
  Timer? timer;
  Map<String, dynamic>? account;
  List<dynamic> positions = [];
  String status = 'Not connected';
  bool dark = false, unlocked = false, configured = false, hasPin = false, useBiometric = false;
  bool busy = false, foreground = true;
  int tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  Future<void> _load() async {
    url.text = await store.read(key: 'base_url') ?? '';
    token.text = await store.read(key: 'api_token') ?? '';
    dark = (await store.read(key: 'dark')) == 'true';
    useBiometric = (await store.read(key: 'biometric')) == 'true';
    hasPin = (await store.read(key: 'pin_hash')) != null;
    configured = url.text.isNotEmpty && token.text.isNotEmpty;
    if (mounted) setState(() {});
  }

  String _hash(String value, String salt) => sha256.convert(utf8.encode('$salt:$value')).toString();

  Future<void> _unlock() async {
    final value = pin.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(value)) {
      _message('Enter exactly six digits');
      return;
    }
    if (!hasPin) {
      final salt = List.generate(24, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await store.write(key: 'pin_salt', value: salt);
      await store.write(key: 'pin_hash', value: _hash(value, salt));
      hasPin = true;
    } else {
      final salt = await store.read(key: 'pin_salt') ?? '';
      if (_hash(value, salt) != await store.read(key: 'pin_hash')) {
        _message('Incorrect PIN');
        return;
      }
    }
    pin.clear();
    setState(() => unlocked = true);
    _start();
  }

  Future<void> _fingerprint() async {
    try {
      if (!useBiometric || !hasPin) return;
      final ok = await biometric.authenticate(localizedReason: 'Unlock MT5 dashboard', options: const AuthenticationOptions(biometricOnly: true, stickyAuth: true));
      if (ok && mounted) {
        setState(() => unlocked = true);
        _start();
      }
    } catch (_) {
      _message('Biometric authentication unavailable');
    }
  }

  void _start() {
    timer?.cancel();
    if (unlocked && configured && foreground) {
      _refresh();
      timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (busy || !mounted || !foreground || !unlocked || !configured) return;
    busy = true;
    try {
      final base = url.text.trim().replaceAll(RegExp(r'/+$'), '');
      if (!base.startsWith('https://')) throw Exception('HTTPS required');
      final headers = {'Authorization': 'Bearer ${token.text.trim()}'};
      final results = await Future.wait([
        http.get(Uri.parse('$base/account'), headers: headers).timeout(const Duration(seconds: 20)),
        http.get(Uri.parse('$base/positions'), headers: headers).timeout(const Duration(seconds: 20)),
      ]);
      if (results.any((r) => r.statusCode != 200)) {
        throw Exception('API returned ${results.map((r) => r.statusCode).join(', ')}');
      }
      final a = jsonDecode(results[0].body);
      final p = jsonDecode(results[1].body);
      if (a is! Map<String, dynamic> || p is! List) throw Exception('Unexpected API response');
      if (mounted) setState(() {
        account = a;
        positions = p;
        status = 'Connected • ${DateTime.now().toLocal().toString().substring(11, 19)}';
      });
    } on TimeoutException {
      if (mounted) setState(() => status = 'API timeout (20s). Check MT5 backend /account and /positions response times.');
    } catch (e) {
      if (mounted) setState(() => status = 'Offline / error: $e');
    } finally {
      busy = false;
    }
  }

  Future<void> _save() async {
    final base = url.text.trim().replaceAll(RegExp(r'/+$'), '');
    if (!base.startsWith('https://') || Uri.tryParse(base)?.host.isEmpty != false) {
      _message('Enter a valid private HTTPS base URL');
      return;
    }
    if (token.text.trim().length < 32) {
      _message('API token must be at least 32 characters');
      return;
    }
    await store.write(key: 'base_url', value: base);
    await store.write(key: 'api_token', value: token.text.trim());
    configured = true;
    setState(() => tab = 0);
    _start();
  }

  void _message(String msg) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (!foreground) {
      timer?.cancel();
      setState(() => unlocked = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    url.dispose();
    token.dispose();
    pin.dispose();
    super.dispose();
  }

  String formatNumber(dynamic v, [int digits = 2]) => v is num ? v.toStringAsFixed(digits) : '—';
  Widget metric(String name, dynamic value, String currency) => Card(
    child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(name, style: const TextStyle(fontSize: 13)),
      const SizedBox(height: 8),
      Text('${formatNumber(value)} $currency', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
    ])),
  );

  Widget _dashboard() {
    final a = account;
    final currency = a?['currency']?.toString() ?? '';
    return RefreshIndicator(onRefresh: _refresh, child: ListView(padding: const EdgeInsets.all(12), children: [
      const ListTile(title: Text('REAL ACCOUNT • READ ONLY', style: TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('No trade placement or modification available')),
      ListTile(title: Text(status), leading: Icon(status.startsWith('Connected') ? Icons.cloud_done : Icons.cloud_off)),
      if (a == null) const ListTile(title: Text('Waiting for account data...')),
      if (a != null) ...[
        Text('Server: ${a['server'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        GridView.count(crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), childAspectRatio: 1.5, children: [
          metric('Balance', a['balance'], currency),
          metric('Equity', a['equity'], currency),
          metric('Floating P/L', a['profit'], currency),
          metric('Free Margin', a['margin_free'], currency),
        ]),
        ListTile(title: const Text('Margin used'), trailing: Text('${formatNumber(a['margin'])} $currency')),
        ListTile(title: const Text('Open positions'), trailing: Text('${positions.length}')),
        const Padding(padding: EdgeInsets.all(12), child: Text('Quotes: no dedicated quote endpoint yet. Position current prices appear in Positions.', style: TextStyle(fontSize: 12))),
      ],
    ]));
  }

  Widget _positions() => RefreshIndicator(onRefresh: _refresh, child: ListView.builder(
    itemCount: positions.isEmpty ? 1 : positions.length,
    itemBuilder: (context, i) {
      if (positions.isEmpty) return const ListTile(title: Text('No positions returned'));
      final p = positions[i] as Map<String, dynamic>;
      final isBuy = p['type'] == 0;
      return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: ExpansionTile(
        title: Text('${p['symbol']} • ${isBuy ? 'BUY' : 'SELL'} • ${formatNumber(p['volume'])} lots'),
        subtitle: Text('P/L: ${formatNumber(p['profit'])} ${account?['currency'] ?? ''}'),
        children: [
          ListTile(title: const Text('Ticket'), trailing: Text('${p['ticket']}')),
          ListTile(title: const Text('Entry / Current'), trailing: Text('${formatNumber(p['price_open'], 3)} / ${formatNumber(p['price_current'], 3)}')),
          ListTile(title: const Text('Stop Loss'), trailing: Text(p['sl'] == 0 ? 'Not set' : formatNumber(p['sl'], 3))),
          ListTile(title: const Text('Take Profit'), trailing: Text(p['tp'] == 0 ? 'Not set' : formatNumber(p['tp'], 3))),
        ],
      ));
    },
  ));

  Widget _settings() => ListView(padding: const EdgeInsets.all(18), children: [
    const Text('Private API connection', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
    const SizedBox(height: 12),
    TextField(controller: url, decoration: const InputDecoration(labelText: 'Tailscale HTTPS base URL', border: OutlineInputBorder()), keyboardType: TextInputType.url),
    const SizedBox(height: 12),
    TextField(controller: token, obscureText: true, enableSuggestions: false, autocorrect: false, decoration: const InputDecoration(labelText: 'API token', border: OutlineInputBorder())),
    const SizedBox(height: 12),
    FilledButton(onPressed: _save, child: const Text('Save secure connection')),
    SwitchListTile(title: const Text('Dark theme'), value: dark, onChanged: (v) async {
      await store.write(key: 'dark', value: '$v');
      setState(() => dark = v);
    }),
    SwitchListTile(title: const Text('Fingerprint unlock'), subtitle: const Text('Requires device biometrics and PIN fallback'), value: useBiometric, onChanged: (v) async {
      if (v && !await biometric.canCheckBiometrics) {
        _message('Biometrics not available');
        return;
      }
      await store.write(key: 'biometric', value: '$v');
      setState(() => useBiometric = v);
    }),
    const ListTile(title: Text('Refresh interval'), subtitle: Text('Every 1 second while open')),
    const ListTile(title: Text('Safety mode'), subtitle: Text('Read-only — real-account trade operations disabled')),
    OutlinedButton(onPressed: () { timer?.cancel(); setState(() => unlocked = false); }, child: const Text('Lock now')),
  ]);

  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    title: 'Exness Trade Dashboard',
    themeMode: dark ? ThemeMode.dark : ThemeMode.light,
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    darkTheme: ThemeData(colorSchemeSeed: Colors.indigo, brightness: Brightness.dark, useMaterial3: true),
    home: Scaffold(
      appBar: AppBar(title: const Text('Exness Trade Dashboard')),
      body: !unlocked
          ? Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 360), child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.lock_outline, size: 56),
              const SizedBox(height: 12),
              Text(hasPin ? 'Enter your 6-digit PIN' : 'Create a 6-digit PIN', style: const TextStyle(fontSize: 20)),
              const SizedBox(height: 18),
              TextField(controller: pin, keyboardType: TextInputType.number, obscureText: true, maxLength: 6, decoration: const InputDecoration(labelText: '6-digit PIN', border: OutlineInputBorder())),
              FilledButton(onPressed: _unlock, child: Text(hasPin ? 'Unlock' : 'Set PIN')),
              if (hasPin && useBiometric) TextButton.icon(onPressed: _fingerprint, icon: const Icon(Icons.fingerprint), label: const Text('Unlock with fingerprint')),
            ]))))
          : IndexedStack(index: tab, children: [_dashboard(), _positions(), _settings()]),
      bottomNavigationBar: unlocked ? NavigationBar(selectedIndex: tab, onDestinationSelected: (v) => setState(() => tab = v), destinations: const [
        NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Dashboard'),
        NavigationDestination(icon: Icon(Icons.list_alt), label: 'Positions'),
        NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
      ]) : null,
    ),
  );
}
