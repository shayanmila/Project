import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

void main() => runApp(const TradeApp());

class TradeApp extends StatefulWidget {
  const TradeApp({super.key});
  @override
  State<TradeApp> createState() => _TradeAppState();
}

class _TradeAppState extends State<TradeApp> with WidgetsBindingObserver {
  final store = const FlutterSecureStorage();
  final url = TextEditingController();
  final token = TextEditingController();
  Timer? timer;
  Map<String, dynamic>? account;
  List<dynamic> positions = [];
  String status = 'Not connected';
  bool dark = false, configured = false;
  int refreshSeconds = 5;
  bool busy = false, foreground = true;
  int tab = 0;
  final symbolInput = TextEditingController();
  final lotsInput = TextEditingController(text: '0.01');
  final slInput = TextEditingController();
  final tpInput = TextEditingController();
  final gridCountInput = TextEditingController(text: '3');
  final gridSpacingInput = TextEditingController();
  String side = 'BUY';

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
    refreshSeconds = int.tryParse(await store.read(key: 'refresh_seconds') ?? '') ?? 5;
    if (![1, 2, 5, 10, 15, 30, 60].contains(refreshSeconds)) refreshSeconds = 5;
    configured = url.text.isNotEmpty && token.text.isNotEmpty;
    if (mounted) setState(() {});
    _start();
  }

  void _start() {
    timer?.cancel();
    if (configured && foreground) {
      _refresh();
      timer = Timer.periodic(Duration(seconds: refreshSeconds), (_) => _refresh());
    }
  }

  Future<void> _refresh() async {
    if (busy || !mounted || !foreground || !configured) return;
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
    } else {
      _start();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    timer?.cancel();
    url.dispose();
    token.dispose();
    for (final c in [symbolInput, lotsInput, slInput, tpInput, gridCountInput, gridSpacingInput]) { c.dispose(); }
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
      const ListTile(title: Text('REAL ACCOUNT • EXECUTION DISABLED', style: TextStyle(fontWeight: FontWeight.bold)), subtitle: Text('Trade controls are previews only; no orders will be sent')),
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

  Future<void> _preview(String title, String details) async {
    await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
      title: Text('$title — Preview only'),
      content: SingleChildScrollView(child: Text('$details\n\nLIVE EXECUTION DISABLED. No MT5 orders will be sent.')),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
    ));
  }
  Widget _field(TextEditingController c, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: TextField(controller: c, decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())),
  );
  bool _validOrder() {
    final lots = double.tryParse(lotsInput.text.trim());
    final symbol = symbolInput.text.trim();
    final prices = [slInput, tpInput].every((c) => c.text.trim().isEmpty || ((double.tryParse(c.text.trim()) ?? -1) >= 0));
    return RegExp(r'^[A-Za-z0-9._-]{1,32}$').hasMatch(symbol) && lots != null && lots.isFinite && lots > 0 && prices;
  }
  Widget _tradeControls() => ListView(padding: const EdgeInsets.all(16), children: [
    const Text('New trade — preview only', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
    const SizedBox(height: 12),
    _field(symbolInput, 'Exact MT5 symbol (e.g. XAUUSDc)'),
    SegmentedButton<String>(segments: const [ButtonSegment(value: 'BUY', label: Text('BUY')), ButtonSegment(value: 'SELL', label: Text('SELL'))], selected: {side}, onSelectionChanged: (v) => setState(() => side = v.first)),
    const SizedBox(height: 12),
    _field(lotsInput, 'Lot size'), _field(slInput, 'Stop Loss price (optional)'), _field(tpInput, 'Take Profit price (optional)'),
    FilledButton(onPressed: () {
      if (!_validOrder()) { _message('Check symbol, lots and SL/TP'); return; }
      _preview('New trade', 'Symbol: ${symbolInput.text.trim()}\nSide: $side\nLots: ${lotsInput.text}\nSL: ${slInput.text}\nTP: ${tpInput.text}');
    }, child: const Text('Preview new trade')),
    const Divider(height: 36),
    const Text('Grid configuration', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
    const Text('Uses symbol, direction, lots, SL and TP above. Spacing is in price units.'),
    const SizedBox(height: 12),
    _field(gridCountInput, 'Grid quantity (1–20)'), _field(gridSpacingInput, 'Grid spacing (price difference)'),
    FilledButton.tonal(onPressed: () {
      final count = int.tryParse(gridCountInput.text.trim());
      final spacing = double.tryParse(gridSpacingInput.text.trim());
      if (!_validOrder() || count == null || count < 1 || count > 20 || spacing == null || !spacing.isFinite || spacing <= 0) {
        _message('Check grid quantity (1–20) and positive spacing'); return;
      }
      final totalLots = count * double.parse(lotsInput.text.trim());
      _preview('Grid', 'Symbol: ${symbolInput.text.trim()}\nSide: $side\nOrders: $count\nLots per order: ${lotsInput.text}\nTotal lots: $totalLots\nSpacing: $spacing\nSL: ${slInput.text}\nTP: ${tpInput.text}\nOrder type and broker rules must be validated before execution.');
    }, child: const Text('Preview grid')),
  ]);
  Widget _positions() => RefreshIndicator(onRefresh: _refresh, child: ListView.builder(
    itemCount: positions.isEmpty ? 1 : positions.length + 1,
    itemBuilder: (context, i) {
      if (positions.isEmpty) return const ListTile(title: Text('No positions returned'));
      if (i == 0) return _closeBySymbol();
      final p = positions[i - 1] as Map<String, dynamic>;
      final isBuy = p['type'] == 0;
      return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5), child: ExpansionTile(
        title: Text('${p['symbol']} • ${isBuy ? 'BUY' : 'SELL'} • ${formatNumber(p['volume'])} lots'),
        subtitle: Text('P/L: ${formatNumber(p['profit'])} ${account?['currency'] ?? ''}'),
        children: [
          ListTile(title: const Text('Ticket'), trailing: Text('${p['ticket']}')),
          ListTile(title: const Text('Entry / Current'), trailing: Text('${formatNumber(p['price_open'], 3)} / ${formatNumber(p['price_current'], 3)}')),
          ListTile(title: const Text('Stop Loss'), trailing: Text(p['sl'] == 0 ? 'Not set' : formatNumber(p['sl'], 3))),
          ListTile(title: const Text('Take Profit'), trailing: Text(p['tp'] == 0 ? 'Not set' : formatNumber(p['tp'], 3))),
          Wrap(spacing: 8, children: [OutlinedButton(onPressed: () => _preview('Edit SL/TP', 'Ticket: ${p['ticket']}\nSymbol: ${p['symbol']}\nCurrent SL: ${p['sl']}\nCurrent TP: ${p['tp']}'), child: const Text('SL / TP')), OutlinedButton(onPressed: () => _preview('Close position', 'Ticket: ${p['ticket']}\nSymbol: ${p['symbol']}\nLots: ${p['volume']}'), child: const Text('Close'))]),
        ],
      ));
    },
  ));

  Widget _closeBySymbol() {
    final symbols = positions.whereType<Map<String, dynamic>>().map((p) => p['symbol'].toString()).toSet().toList()..sort();
    return Column(children: [for (final symbol in symbols) OutlinedButton.icon(
      onPressed: () {
        final matches = positions.where((p) => p is Map<String, dynamic> && p['symbol'] == symbol).toList();
        _preview('Close all by symbol', 'Symbol: $symbol\nPositions: ${matches.length}\nOnly this exact symbol would be affected.');
      }, icon: const Icon(Icons.layers_clear), label: Text('Close all $symbol — Preview'),
    )]);
  }
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
    ListTile(
      title: const Text('Refresh interval'),
      subtitle: Text('Every $refreshSeconds seconds while app is open'),
      trailing: DropdownButton<int>(
        value: refreshSeconds,
        items: const [1, 2, 5, 10, 15, 30, 60]
            .map((seconds) => DropdownMenuItem<int>(
                  value: seconds,
                  child: Text('$seconds sec'),
                ))
            .toList(),
        onChanged: (value) async {
          if (value == null) return;
          await store.write(key: 'refresh_seconds', value: '$value');
          setState(() => refreshSeconds = value);
          _start();
        },
      ),
    ),
    const ListTile(title: Text('Safety mode'), subtitle: Text('Trade previews only — execution disabled')),
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
      body: IndexedStack(index: tab, children: [_dashboard(), _positions(), _tradeControls(), _settings()]),
      bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (v) => setState(() => tab = v), destinations: const [
        NavigationDestination(icon: Icon(Icons.dashboard_outlined), label: 'Dashboard'),
        NavigationDestination(icon: Icon(Icons.list_alt), label: 'Positions'),
        NavigationDestination(icon: Icon(Icons.add_chart), label: 'Trade'),
        NavigationDestination(icon: Icon(Icons.settings_outlined), label: 'Settings'),
      ]),
    ),
  );
}
