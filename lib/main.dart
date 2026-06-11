import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

// ─── Constants ───────────────────────────────────────────────────────────────
const int kCurrentBuild = 43;
const String kCurrentVersion = '1.5.7';
const String kApiBase = 'http://85.192.38.213:8766';
const String kGitHubRepo = 'Hiagar11/trading-panel';

const kBg = Color(0xFF080808);
const kCard = Color(0xFF101010);
const kGold = Color(0xFFD4A017);
const kGreen = Color(0xFF22D3A5);
const kRed = Color(0xFFFF4466);
const kDim = Color(0xFF6B6B6B);

// ─── Install channel ─────────────────────────────────────────────────────────
const _installChannel = MethodChannel('com.example.trading_panel/install');

// ─── Notifications ────────────────────────────────────────────────────────────
final FlutterLocalNotificationsPlugin _notificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> initNotifications({
  void Function(NotificationResponse)? onTap,
}) async {
  const AndroidInitializationSettings androidSettings =
      AndroidInitializationSettings('@mipmap/ic_launcher');
  final InitializationSettings initSettings = InitializationSettings(
    android: androidSettings,
  );
  await _notificationsPlugin.initialize(
    initSettings,
    onDidReceiveNotificationResponse: onTap,
  );
  const AndroidNotificationChannel signalsChannel = AndroidNotificationChannel(
    'signals',
    'Сигналы',
    description: 'Уведомления о новых торговых сигналах',
    importance: Importance.high,
  );
  const AndroidNotificationChannel updateChannel = AndroidNotificationChannel(
    'update_channel',
    'Обновления',
    description: 'Уведомления об обновлениях приложения',
    importance: Importance.max,
  );
  final androidImpl = _notificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
  await androidImpl?.createNotificationChannel(signalsChannel);
  await androidImpl?.createNotificationChannel(updateChannel);
}

Future<void> showSignalNotification(String title, String body) async {
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'signals',
    'Сигналы',
    channelDescription: 'Уведомления о новых торговых сигналах',
    importance: Importance.high,
    priority: Priority.high,
  );
  const NotificationDetails details =
      NotificationDetails(android: androidDetails);
  await _notificationsPlugin.show(0, title, body, details);
}

// ─── Notification tap handler (top-level, used by initNotifications) ─────────
void _onNotificationTap(NotificationResponse response) async {
  final payload = response.payload;
  if (payload == null || payload.isEmpty) return;
  if (payload == 'do_update') {
    // Update notification tapped — download is already in progress; nothing to do.
    return;
  }
  try {
    await _installChannel.invokeMethod('installApk', {'path': payload});
  } catch (e) {
    debugPrint('Install error: $e');
  }
}

// ─── App entry ───────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications(onTap: _onNotificationTap);
  runApp(const TradingPanelApp());
}

class TradingPanelApp extends StatelessWidget {
  const TradingPanelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Trading Panel',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(
          primary: kGold,
          secondary: kGold,
          surface: kCard,
          background: kBg,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: kCard,
          elevation: 0,
          titleTextStyle: TextStyle(
            color: kGold,
            fontSize: 18,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
          iconTheme: IconThemeData(color: kGold),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: kCard,
          selectedItemColor: kGold,
          unselectedItemColor: kDim,
          type: BottomNavigationBarType.fixed,
        ),
        cardTheme: const CardThemeData(
          color: kCard,
          elevation: 0,
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white),
          bodySmall: TextStyle(color: kDim),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: kGold,
          foregroundColor: Colors.black,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

// ─── Session management ───────────────────────────────────────────────────────
class SessionManager {
  static const _keyToken = 'session_token';
  static const _keyUserId = 'session_user_id';
  static const _keyUserName = 'session_user_name';
  static const _keyExpiry = 'session_expiry';

  static String? token;
  static String? userId;
  static String? userName;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final expiry = prefs.getInt(_keyExpiry) ?? 0;
    if (DateTime.now().millisecondsSinceEpoch > expiry) {
      await clear();
      return;
    }
    token = prefs.getString(_keyToken);
    userId = prefs.getString(_keyUserId);
    userName = prefs.getString(_keyUserName);
  }

  static Future<void> save(
      String t, String id, String name) async {
    final prefs = await SharedPreferences.getInstance();
    token = t;
    userId = id;
    userName = name;
    final expiry =
        DateTime.now().add(const Duration(hours: 24)).millisecondsSinceEpoch;
    await prefs.setString(_keyToken, t);
    await prefs.setString(_keyUserId, id);
    await prefs.setString(_keyUserName, name);
    await prefs.setInt(_keyExpiry, expiry);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    token = null;
    userId = null;
    userName = null;
    await prefs.remove(_keyToken);
    await prefs.remove(_keyUserId);
    await prefs.remove(_keyUserName);
    await prefs.remove(_keyExpiry);
  }

  static bool get isLoggedIn => token != null;
}

// ─── API helpers ──────────────────────────────────────────────────────────────
Map<String, String> _headers({bool auth = false}) {
  final h = {'Content-Type': 'application/json'};
  if (auth && SessionManager.token != null) {
    h['X-User-Token'] = SessionManager.token!;
  }
  return h;
}

Future<Map<String, dynamic>?> apiGet(String path,
    {bool auth = false}) async {
  try {
    final resp = await http
        .get(Uri.parse('$kApiBase$path'), headers: _headers(auth: auth))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      final decoded = jsonDecode(resp.body);
      if (decoded is Map<String, dynamic>) return decoded;
      return {'_list': decoded};
    }
  } catch (_) {}
  return null;
}

Future<List<dynamic>?> apiGetList(String path, {bool auth = false}) async {
  try {
    final resp = await http
        .get(Uri.parse('$kApiBase$path'), headers: _headers(auth: auth))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode == 200) {
      final decoded = jsonDecode(resp.body);
      if (decoded is List) return decoded;
      if (decoded is Map && decoded.containsKey('_list')) {
        return decoded['_list'] as List;
      }
    }
  } catch (_) {}
  return null;
}

Future<Map<String, dynamic>?> apiPost(String path, Map<String, dynamic> body,
    {bool auth = false}) async {
  try {
    final resp = await http
        .post(Uri.parse('$kApiBase$path'),
            headers: _headers(auth: auth), body: jsonEncode(body))
        .timeout(const Duration(seconds: 10));
    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      if (resp.body.isEmpty) return {};
      return jsonDecode(resp.body) as Map<String, dynamic>;
    }
  } catch (_) {}
  return null;
}

Future<bool> apiDelete(String path, {bool auth = false}) async {
  try {
    final resp = await http
        .delete(Uri.parse('$kApiBase$path'), headers: _headers(auth: auth))
        .timeout(const Duration(seconds: 10));
    return resp.statusCode >= 200 && resp.statusCode < 300;
  } catch (_) {
    return false;
  }
}

Future<bool> apiPatch(String path, Map<String, dynamic> body,
    {bool auth = false}) async {
  try {
    final resp = await http
        .patch(Uri.parse('$kApiBase$path'),
            headers: _headers(auth: auth), body: jsonEncode(body))
        .timeout(const Duration(seconds: 10));
    return resp.statusCode >= 200 && resp.statusCode < 300;
  } catch (_) {
    return false;
  }
}

// ─── HomeScreen ───────────────────────────────────────────────────────────────
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _watcherAlive = false;
  double _balance = 0;
  int _openPositions = 0;
  Timer? _statusTimer;
  Timer? _checkUpdateTimer;
  Timer? _healthTimer;
  WebSocket? _ws;
  bool _wsConnected = false;
  double _downloadProgress = 0.0;
  String _latestVersion = kCurrentVersion;
  bool _updateInProgress = false;
  bool _botHealthy = false;
  int _lastSignalSecondsAgo = -1;
  Future? _pendingReconnect;
  int _reconnectAttempts = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await SessionManager.load();
    await _requestPermissions();
    _fetchStatus();
    _connectWs();
    // Fallback polling every 30s in case WebSocket drops and reconnect is pending
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchStatus());
    // GitHub fallback update check (runs when VPS is unreachable)
    _checkUpdate();
    _checkUpdateTimer = Timer.periodic(const Duration(minutes: 5), (_) => _checkUpdate());
    _fetchHealth();
    _healthTimer = Timer.periodic(const Duration(seconds: 60), (_) => _fetchHealth());
  }

  void _connectWs() async {
    _pendingReconnect = null;
    try {
      _ws = await WebSocket.connect('ws://85.192.38.213:8766/ws');
      _reconnectAttempts = 0;
      _ws!.listen(
        (data) {
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          if (mounted) {
            setState(() {
              _wsConnected = true;
              _balance = (msg['balance'] as num?)?.toDouble() ?? _balance;
              _watcherAlive = msg['watcher_alive'] == true;
              final positions = msg['positions'];
              if (positions is List) {
                _openPositions = positions.length;
              }
            });
            if (msg['build'] != null) {
              final serverBuild = msg['build'] as int;
              if (serverBuild > kCurrentBuild && !_updateInProgress) {
                _updateInProgress = true;
                _notificationsPlugin.show(
                  99,
                  'Доступно обновление',
                  'Версия $serverBuild готова к установке. Нажми чтобы загрузить.',
                  const NotificationDetails(
                    android: AndroidNotificationDetails(
                      'update_channel',
                      'Обновления',
                      channelDescription: 'Уведомления об обновлениях приложения',
                      importance: Importance.max,
                      priority: Priority.high,
                      icon: '@mipmap/ic_launcher',
                    ),
                  ),
                  payload: 'do_update',
                );
                _downloadAndInstall('');
              }
            }
          }
        },
        onDone: () {
          if (mounted) setState(() => _wsConnected = false);
          _scheduleReconnect();
        },
        onError: (_) {
          if (mounted) setState(() => _wsConnected = false);
          _scheduleReconnect();
        },
      );
    } catch (_) {
      if (mounted) setState(() => _wsConnected = false);
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_pendingReconnect != null) return;
    _reconnectAttempts++;
    final delaySecs = [5, 10, 30, 60].elementAtOrNull(_reconnectAttempts - 1) ?? 60;
    _pendingReconnect = Future.delayed(Duration(seconds: delaySecs), _connectWs);
  }

  Future<void> _requestPermissions() async {
    await [
      Permission.notification,
    ].request();
  }

  Future<void> _fetchStatus() async {
    final data = await apiGet('/status');
    if (data != null && mounted) {
      setState(() {
        _watcherAlive = data['watcher_alive'] == true;
        _balance = (data['balance'] as num?)?.toDouble() ?? _balance;
        _openPositions = (data['open_positions'] as num?)?.toInt() ?? _openPositions;
      });
      if (data['build'] != null) {
        final serverBuild = data['build'] as int;
        if (serverBuild > kCurrentBuild && !_updateInProgress) {
          _updateInProgress = true;
          _notificationsPlugin.show(
            99,
            'Доступно обновление',
            'Версия $serverBuild готова к установке.',
            const NotificationDetails(
              android: AndroidNotificationDetails(
                'update_channel',
                'Обновления',
                channelDescription: 'Уведомления об обновлениях',
                importance: Importance.max,
                priority: Priority.high,
                icon: '@mipmap/ic_launcher',
              ),
            ),
            payload: 'do_update',
          );
          _downloadAndInstall('');
        }
      }
    }
  }

  Future<void> _checkUpdate() async {
    try {
      final resp = await http
          .get(Uri.parse(
              'https://api.github.com/repos/$kGitHubRepo/releases/latest'))
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final tag = (data['tag_name'] as String?)?.replaceFirst('v', '') ?? '';
        final parts = tag.split('+');
        if (parts.length == 2) {
          final remoteBuild = int.tryParse(parts[1]) ?? 0;
          if (remoteBuild > kCurrentBuild && mounted) {
            _latestVersion = parts[0]; // save version string (e.g. "1.4.7")
            final assets = data['assets'] as List?;
            if (assets != null && assets.isNotEmpty) {
              final url = assets[0]['browser_download_url'] as String?;
              if (url != null) {
                _showUpdateDialog(tag, url);
              }
            }
          }
        }
      }
    } catch (_) {}
  }

  void _showUpdateDialog(String version, String url) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('Обновление $version',
            style: const TextStyle(color: kGold)),
        content: const Text(
            'Доступна новая версия. Установить?',
            style: TextStyle(color: Colors.white)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Позже', style: TextStyle(color: kDim)),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _downloadAndInstall(url);
            },
            child: const Text('Установить', style: TextStyle(color: kGold)),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadAndInstall(String _ignored) async {
    // Android 8+: REQUEST_INSTALL_PACKAGES must be granted at runtime
    if (await Permission.requestInstallPackages.isDenied) {
      final status = await Permission.requestInstallPackages.request();
      if (!status.isGranted) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Разрешите установку из неизвестных источников в настройках'),
          backgroundColor: kCard,
          duration: Duration(seconds: 5),
        ));
        _updateInProgress = false;
        return;
      }
    }

    // Сохранить context до async операций
    final scaffoldMsg = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);

    // Показать диалог прогресса (не snackbar — он исчезает)
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        title: const Text('Загрузка...', style: TextStyle(color: kGold)),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: kGold),
            SizedBox(height: 12),
            Text('Скачивание обновления', style: TextStyle(color: Colors.white)),
          ],
        ),
      ),
    );

    try {
      // Использовать временную директорию — FileProvider поддерживает cache-path
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/trading_panel_update.apk');

      // Стриминговый download с отображением прогресса
      final client = http.Client();
      final request = http.Request('GET', Uri.parse('http://85.192.38.213:8766/download/apk'));
      final response = await client.send(request);
      final bytes = <int>[];
      int received = 0;
      final total = response.contentLength ?? 0;
      await for (final chunk in response.stream) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (total > 0) setState(() => _downloadProgress = received / total);
      }
      await file.writeAsBytes(bytes);
      client.close();

      // Закрыть диалог
      nav.pop();

      // Попытаться открыть установщик напрямую через FileProvider
      try {
        await _installChannel.invokeMethod('installApk', {'path': file.path});
      } catch (e) {
        // Fallback: системное уведомление
        await _showInstallNotification(file.path);
      }
    } catch (e) {
      // Закрыть диалог если открыт
      try { nav.pop(); } catch (_) {}
      scaffoldMsg.showSnackBar(SnackBar(
        content: Text('Ошибка загрузки: $e'),
        backgroundColor: kCard,
        duration: const Duration(seconds: 5),
      ));
    } finally {
      // Всегда сбрасываем состояние, даже при исключении
      setState(() => _downloadProgress = 0.0);
      _updateInProgress = false;
    }
  }

  Future<void> _showInstallNotification(String apkPath) async {
    const androidDetails = AndroidNotificationDetails(
      'update_channel',
      'Обновления',
      channelDescription: 'Уведомления об обновлениях приложения',
      importance: Importance.max,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
    );
    const details = NotificationDetails(android: androidDetails);
    await _notificationsPlugin.show(
      999,
      'Обновление готово',
      'Нажмите для установки Trading Panel v$_latestVersion',
      details,
      payload: apkPath,
    );
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: kCard,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _setWatcher(bool start) async {
    final action = start ? 'start' : 'stop';
    await apiPost('/watcher', {'action': action});
    await _fetchStatus();
  }

  Future<void> _fetchHealth() async {
    final data = await apiGet('/health');
    if (mounted) {
      setState(() {
        _botHealthy = data?['vps'] == true;
        _lastSignalSecondsAgo =
            (data?['last_signal_seconds_ago'] as num?)?.toInt() ?? -1;
      });
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _checkUpdateTimer?.cancel();
    _healthTimer?.cancel();
    _ws?.close();
    _pendingReconnect = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('TRADING PANEL v$kCurrentVersion'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _wsConnected ? Colors.green : Colors.red,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  _wsConnected ? 'ONLINE' : 'OFFLINE',
                  style: TextStyle(
                    color: _wsConnected ? Colors.green : Colors.red,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _lastSignalSecondsAgo < 0
                        ? Colors.grey
                        : _lastSignalSecondsAgo > 3600
                            ? Colors.amber
                            : Colors.green,
                  ),
                ),
                const SizedBox(width: 3),
                if (_lastSignalSecondsAgo >= 0)
                  Text(
                    _lastSignalSecondsAgo < 60
                        ? '<1m'
                        : _lastSignalSecondsAgo < 3600
                            ? '${_lastSignalSecondsAgo ~/ 60}m'
                            : '${_lastSignalSecondsAgo ~/ 3600}h',
                    style: TextStyle(
                      color: _lastSignalSecondsAgo > 3600
                          ? Colors.amber
                          : Colors.green,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
          _WatcherControlWidget(
            alive: _watcherAlive,
            onPlay: () => _setWatcher(true),
            onPause: () => _setWatcher(false),
          ),
          IconButton(
            icon: const Icon(Icons.account_circle),
            onPressed: () => _showProfileSheet(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_downloadProgress > 0 && _downloadProgress < 1.0)
            LinearProgressIndicator(
              value: _downloadProgress,
              minHeight: 3,
              backgroundColor: Colors.grey[800],
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
            ),
          Expanded(child: ChannelsTab(balance: _balance)),
        ],
      ),
    );
  }

  void _showProfileSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => ProfileSheet(
        onChanged: () {
          setState(() {});
          Navigator.pop(ctx);
        },
      ),
    );
  }
}

// ─── Watcher control widget ───────────────────────────────────────────────────
class _WatcherControlWidget extends StatelessWidget {
  final bool alive;
  final VoidCallback onPlay;
  final VoidCallback onPause;
  const _WatcherControlWidget(
      {required this.alive, required this.onPlay, required this.onPause});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            Icons.play_arrow,
            color: alive ? kGold : kDim,
          ),
          onPressed: onPlay,
          tooltip: 'Запустить наблюдение',
        ),
        IconButton(
          icon: Icon(
            Icons.pause,
            color: alive ? kDim : kGold,
          ),
          onPressed: onPause,
          tooltip: 'Остановить наблюдение',
        ),
      ],
    );
  }
}

// ─── Profile Sheet ────────────────────────────────────────────────────────────
class ProfileSheet extends StatefulWidget {
  final VoidCallback onChanged;
  const ProfileSheet({super.key, required this.onChanged});

  @override
  State<ProfileSheet> createState() => _ProfileSheetState();
}

class _ProfileSheetState extends State<ProfileSheet> {
  List<dynamic> _users = [];
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    final data = await apiGetList('/users');
    if (mounted) setState(() => _users = data ?? []);
  }

  Future<void> _login(String userId) async {
    final pin = await _askPin(context);
    if (pin == null) return;
    setState(() => _loading = true);
    final resp = await apiPost('/users/$userId/login', {'pin': pin});
    setState(() => _loading = false);
    if (resp != null && resp['token'] != null) {
      final name = _users
          .firstWhere((u) => u['id'].toString() == userId,
              orElse: () => {'name': 'User'})['name']
          .toString();
      await SessionManager.save(resp['token'], userId, name);
      widget.onChanged();
    } else {
      _showToast('Неверный PIN');
    }
  }

  Future<void> _createUser() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => const _CreateUserDialog(),
    );
    if (result == null) return;
    setState(() => _loading = true);
    final resp = await apiPost('/users', result);
    setState(() => _loading = false);
    if (resp != null) {
      _showToast('Профиль создан');
      _loadUsers();
    } else {
      _showToast('Ошибка создания');
    }
  }

  Future<void> _logout() async {
    if (SessionManager.userId != null) {
      await apiPost('/users/${SessionManager.userId}/logout', {},
          auth: true);
    }
    await SessionManager.clear();
    widget.onChanged();
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: kCard),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Профиль',
              style: TextStyle(
                  color: kGold, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          if (SessionManager.isLoggedIn) ...[
            Row(
              children: [
                const Icon(Icons.account_circle, color: kGold, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(SessionManager.userName ?? 'Пользователь',
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                      Text('ID: ${SessionManager.userId}',
                          style: const TextStyle(color: kDim, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: _logout,
                style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: kRed)),
                child: const Text('Выйти',
                    style: TextStyle(color: kRed)),
              ),
            ),
          ] else ...[
            const Text('Выберите профиль для входа:',
                style: TextStyle(color: kDim)),
            const SizedBox(height: 8),
            if (_loading)
              const CircularProgressIndicator(color: kGold)
            else ...[
              ..._users.map((u) => ListTile(
                    leading: const Icon(Icons.person, color: kDim),
                    title: Text(u['name']?.toString() ?? 'User',
                        style: const TextStyle(color: Colors.white)),
                    subtitle: Text('ID: ${u['id']}',
                        style: const TextStyle(color: kDim, fontSize: 11)),
                    onTap: () => _login(u['id'].toString()),
                  )),
              const Divider(color: kDim),
              TextButton.icon(
                onPressed: _createUser,
                icon: const Icon(Icons.add, color: kGold),
                label: const Text('Создать профиль',
                    style: TextStyle(color: kGold)),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

Future<String?> _askPin(BuildContext context) async {
  final ctrl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: kCard,
      title: const Text('Введите PIN',
          style: TextStyle(color: kGold)),
      content: TextField(
        controller: ctrl,
        obscureText: true,
        keyboardType: TextInputType.number,
        maxLength: 6,
        decoration: const InputDecoration(
          hintText: 'PIN',
          hintStyle: TextStyle(color: kDim),
          counterStyle: TextStyle(color: kDim),
        ),
        style: const TextStyle(color: Colors.white),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Отмена', style: TextStyle(color: kDim)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, ctrl.text),
          child: const Text('Войти', style: TextStyle(color: kGold)),
        ),
      ],
    ),
  );
}

class _CreateUserDialog extends StatefulWidget {
  const _CreateUserDialog();

  @override
  State<_CreateUserDialog> createState() => _CreateUserDialogState();
}

class _CreateUserDialogState extends State<_CreateUserDialog> {
  final _nameCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kCard,
      title: const Text('Новый профиль',
          style: TextStyle(color: kGold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Имя',
              labelStyle: TextStyle(color: kDim),
            ),
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _pinCtrl,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(
              labelText: 'PIN (4-6 цифр)',
              labelStyle: TextStyle(color: kDim),
              counterStyle: TextStyle(color: kDim),
            ),
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена', style: TextStyle(color: kDim)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, {
            'name': _nameCtrl.text,
            'pin': _pinCtrl.text,
          }),
          child: const Text('Создать', style: TextStyle(color: kGold)),
        ),
      ],
    );
  }
}

// ─── Signals Tab ──────────────────────────────────────────────────────────────
class SignalsTab extends StatefulWidget {
  final void Function(Map<String, dynamic>) onNewSignal;
  const SignalsTab({super.key, required this.onNewSignal});

  @override
  State<SignalsTab> createState() => _SignalsTabState();
}

class _SignalsTabState extends State<SignalsTab> {
  List<dynamic> _signals = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;
  String? _lastId;

  @override
  void initState() {
    super.initState();
    _fetch();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _fetch());
  }

  Future<void> _fetch() async {
    final data = await apiGetList('/signals?limit=30');
    if (mounted) {
      setState(() {
        _loading = false;
        if (data != null) {
          _error = null;
          // Check for new signal
          if (data.isNotEmpty) {
            final newest = data.first as Map<String, dynamic>;
            final id = newest['id']?.toString() ??
                newest['timestamp']?.toString();
            if (id != null && id != _lastId && _lastId != null) {
              widget.onNewSignal(newest);
            }
            _lastId = id;
          }
          _signals = data;
        } else {
          _error = 'Ошибка загрузки сигналов';
        }
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kGold));
    }
    return RefreshIndicator(
      color: kGold,
      onRefresh: () async {
        setState(() => _loading = false);
        await _fetch();
      },
      child: _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_error != null) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          SizedBox(
            height: 300,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.error_outline, color: kRed, size: 48),
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: kDim)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() => _loading = true);
                      _fetch();
                    },
                    style: ElevatedButton.styleFrom(backgroundColor: kGold),
                    child: const Text('Повторить',
                        style: TextStyle(color: Colors.black)),
                  ),
                  const SizedBox(height: 8),
                  const Text('↓ потяните для обновления',
                      style: TextStyle(color: kDim, fontSize: 12)),
                ],
              ),
            ),
          ),
        ],
      );
    }
    if (_signals.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: const [
          SizedBox(
            height: 300,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Нет сигналов', style: TextStyle(color: kDim)),
                  SizedBox(height: 8),
                  Text('↓ потяните для обновления',
                      style: TextStyle(color: kDim, fontSize: 12)),
                ],
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      itemCount: _signals.length,
      itemBuilder: (ctx, i) => _SignalCard(signal: _signals[i]),
    );
  }
}

class _SignalCard extends StatelessWidget {
  final dynamic signal;
  const _SignalCard({required this.signal});

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> s =
        signal is Map<String, dynamic> ? signal : {};
    final pair = s['pair'] ?? s['symbol'] ?? s['channel'] ?? '—';
    final direction = (s['direction'] ?? s['side'] ?? s['type'] ?? '')
        .toString()
        .toUpperCase();
    final price = s['price'] ?? s['entry'] ?? s['entry_price'];
    final sl = s['sl'] ?? s['stop_loss'];
    final tp = s['tp'] ?? s['take_profit'];
    final ts = s['timestamp'] ?? s['created_at'] ?? s['time'];
    final isLong = direction.contains('LONG') || direction.contains('BUY');
    final isShort = direction.contains('SHORT') || direction.contains('SELL');
    final dirColor = isLong
        ? kGreen
        : isShort
            ? kRed
            : kDim;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(pair.toString(),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 15)),
                const Spacer(),
                if (direction.isNotEmpty)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: dirColor.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: dirColor, width: 0.5),
                    ),
                    child: Text(direction,
                        style: TextStyle(
                            color: dirColor,
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  ),
                const SizedBox(width: 6),
                _OutcomeBadge(
                  outcome: s['outcome']?.toString() ??
                      s['status']?.toString() ??
                      s['result']?.toString(),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                if (price != null)
                  _InfoChip('Вход', price.toString(), Colors.white),
                if (sl != null)
                  _InfoChip('SL', sl.toString(), kRed),
                if (tp != null)
                  _InfoChip('TP', tp.toString(), kGreen),
              ],
            ),
            if (ts != null) ...[
              const SizedBox(height: 4),
              Text(ts.toString(),
                  style: const TextStyle(color: kDim, fontSize: 11)),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _InfoChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: RichText(
        text: TextSpan(children: [
          TextSpan(
              text: '$label: ',
              style: const TextStyle(color: kDim, fontSize: 12)),
          TextSpan(
              text: value,
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _OutcomeBadge extends StatelessWidget {
  final String? outcome;
  const _OutcomeBadge({this.outcome});

  @override
  Widget build(BuildContext context) {
    final o = outcome?.toLowerCase() ?? '';
    final Color color;
    final String label;
    if (o.contains('tp') || o == 'win' || o == 'profit') {
      color = kGreen;
      label = 'TP HIT ✅';
    } else if (o.contains('sl') || o == 'loss' || o == 'stop') {
      color = kRed;
      label = 'SL HIT ❌';
    } else {
      color = kDim;
      label = 'OPEN ⏳';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.5), width: 0.5),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w600)),
    );
  }
}

// ─── Positions Tab ────────────────────────────────────────────────────────────
class PositionsTab extends StatefulWidget {
  const PositionsTab({super.key});

  @override
  State<PositionsTab> createState() => _PositionsTabState();
}

class _PositionsTabState extends State<PositionsTab> {
  List<dynamic> _positions = [];
  double _balance = 0;
  double _dailyPnl = 0;
  int _tradeCount = 0;
  bool _loading = true;
  String? _error;
  Timer? _timer;
  Timer? _fundingTimer;
  Map<String, double> _fundingRates = {};

  @override
  void initState() {
    super.initState();
    _fetch();
    _fetchFunding();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _fetch());
    _fundingTimer =
        Timer.periodic(const Duration(seconds: 60), (_) => _fetchFunding());
  }

  Future<void> _fetchFunding() async {
    final data = await apiGet('/funding');
    if (data != null && mounted) {
      final rates = <String, double>{};
      data.forEach((k, v) {
        if (v is num) rates[k] = v.toDouble();
      });
      setState(() => _fundingRates = rates);
    }
  }

  Future<void> _fetch() async {
    if (!SessionManager.isLoggedIn) {
      if (mounted) setState(() { _loading = false; _error = null; });
      return;
    }
    final posData = await apiGetList('/positions', auth: true);
    final balData = await apiGet('/balance', auth: true);
    final statsData = await apiGet('/stats/daily', auth: true);
    if (mounted) {
      setState(() {
        _loading = false;
        if (posData != null) {
          _positions = posData;
          _error = null;
        } else {
          _error = 'Ошибка загрузки позиций';
        }
        if (balData != null) {
          _balance = (balData['balance'] as num?)?.toDouble() ?? _balance;
        }
        if (statsData != null) {
          _dailyPnl = (statsData['pnl'] as num?)?.toDouble() ?? _dailyPnl;
          _tradeCount = (statsData['trade_count'] as num?)?.toInt() ?? _tradeCount;
        }
      });
    }
  }

  Future<void> _closePosition(String id) async {
    final ok = await apiDelete('/positions/$id', auth: true);
    if (ok) {
      _showToast('Позиция закрыта');
      _fetch();
    } else {
      _showToast('Ошибка закрытия позиции');
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: kCard),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _fundingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!SessionManager.isLoggedIn) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_outline, color: kDim, size: 48),
            SizedBox(height: 12),
            Text('Войдите в профиль', style: TextStyle(color: kDim)),
            SizedBox(height: 4),
            Text('Нажмите иконку профиля в шапке',
                style: TextStyle(color: kDim, fontSize: 12)),
          ],
        ),
      );
    }
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kGold));
    }
    return RefreshIndicator(
      color: kGold,
      onRefresh: _fetch,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Balance & P&L cards
          Row(
            children: [
              Expanded(
                child: _StatCard(
                  label: 'Баланс',
                  value: '\$${_balance.toStringAsFixed(2)}',
                  color: Colors.white,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatCard(
                  label: 'P&L за день',
                  value: '${_dailyPnl >= 0 ? '+' : ''}\$${_dailyPnl.toStringAsFixed(2)}',
                  color: _dailyPnl >= 0 ? kGreen : kRed,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _StatCard(
                  label: 'Сделки',
                  value: '$_tradeCount',
                  color: kGold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text('Открытые позиции',
              style: TextStyle(
                  color: kDim, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_error != null)
            Center(
                child: Text(_error!, style: const TextStyle(color: kRed)))
          else if (_positions.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text('Нет открытых позиций',
                    style: TextStyle(color: kDim)),
              ),
            )
          else
            ..._positions.map((p) {
              final pair = (p['pair'] ?? p['symbol'] ?? '').toString();
              return _PositionCard(
                position: p,
                onClose: () => _closePosition(p['id'].toString()),
                fundingRate: _fundingRates[pair],
              );
            }),
        ],
      ),
    );
  }
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatCard(
      {required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(color: kDim, fontSize: 11)),
          const SizedBox(height: 4),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 15, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}

class _PositionCard extends StatelessWidget {
  final dynamic position;
  final VoidCallback onClose;
  final double? fundingRate;
  const _PositionCard(
      {required this.position, required this.onClose, this.fundingRate});

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> p =
        position is Map<String, dynamic> ? position : {};
    final pair = p['pair'] ?? p['symbol'] ?? '—';
    final side = (p['side'] ?? p['direction'] ?? '').toString().toUpperCase();
    final entry = p['entry'] ?? p['entry_price'];
    final pnl = (p['pnl'] as num?)?.toDouble() ?? 0;
    final isLong = side.contains('LONG') || side.contains('BUY');

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(pair.toString(),
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: (isLong ? kGreen : kRed).withOpacity(0.15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(side,
                            style: TextStyle(
                                color: isLong ? kGreen : kRed,
                                fontSize: 11,
                                fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  if (entry != null) ...[
                    const SizedBox(height: 4),
                    Text('Вход: $entry',
                        style: const TextStyle(color: kDim, fontSize: 12)),
                  ],
                  if (fundingRate != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'FR: ${fundingRate! >= 0 ? '+' : ''}${(fundingRate! * 100).toStringAsFixed(4)}%',
                      style: TextStyle(
                          color: fundingRate! >= 0 ? kGreen : kRed,
                          fontSize: 11),
                    ),
                  ],
                  Text(
                      'P&L: ${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(2)}',
                      style: TextStyle(
                          color: pnl >= 0 ? kGreen : kRed,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, color: kRed),
              onPressed: onClose,
              tooltip: 'Закрыть позицию',
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Balance Card ─────────────────────────────────────────────────────────────
class _BalanceCard extends StatelessWidget {
  final double balance;
  const _BalanceCard({required this.balance});

  @override
  Widget build(BuildContext context) {
    final color = balance >= 0 ? kGreen : kRed;
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        children: [
          const Text('💰', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          const Text('Баланс:',
              style: TextStyle(color: kDim, fontSize: 14)),
          const SizedBox(width: 6),
          Text(
            '\$${balance.toStringAsFixed(2)}',
            style: TextStyle(
                color: color, fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

// ─── Channels Tab ─────────────────────────────────────────────────────────────
class ChannelsTab extends StatefulWidget {
  final double balance;
  const ChannelsTab({super.key, required this.balance});

  @override
  State<ChannelsTab> createState() => _ChannelsTabState();
}

class _ChannelsTabState extends State<ChannelsTab> {
  List<dynamic> _channels = [];
  bool _loading = true;
  bool _isOwner = false;
  String? _lastSignalId;
  Timer? _signalTimer;

  @override
  void initState() {
    super.initState();
    _fetch();
    _checkNewSignals();
    _signalTimer =
        Timer.periodic(const Duration(seconds: 15), (_) => _checkNewSignals());
  }

  @override
  void dispose() {
    _signalTimer?.cancel();
    super.dispose();
  }

  Future<void> _checkNewSignals() async {
    final data = await apiGetList('/signals?limit=1');
    if (data == null || data.isEmpty) return;
    final raw = data.first;
    if (raw is! Map) return; // guard: malformed API response
    final signal = Map<String, dynamic>.from(raw);
    final id =
        signal['id']?.toString() ?? signal['timestamp']?.toString();
    if (id == null || id.isEmpty) return;
    if (id != _lastSignalId && _lastSignalId != null) {
      final pair =
          (signal['pair'] ?? signal['symbol'] ?? 'UNKNOWN').toString();
      final direction =
          (signal['direction'] ?? signal['side'] ?? '').toString().toUpperCase();
      final entry = signal['price'] ?? signal['entry'] ?? signal['entry_price'];
      final tp = signal['tp'] ?? signal['take_profit'];
      final sl = signal['sl'] ?? signal['stop_loss'];
      final title =
          direction.isNotEmpty ? '$pair $direction' : 'Новый сигнал: $pair';
      final bodyParts = <String>[];
      if (entry != null) bodyParts.add('Вход: \$$entry');
      if (tp != null) bodyParts.add('TP: \$$tp');
      if (sl != null) bodyParts.add('SL: \$$sl');
      final body = bodyParts.isNotEmpty
          ? bodyParts.join(' | ')
          : (signal['channel_title']?.toString() ?? '');
      showSignalNotification(title, body);
    }
    _lastSignalId = id;
  }

  Future<void> _fetch() async {
    final data = await apiGetList('/channels');
    if (SessionManager.isLoggedIn) {
      final me = await apiGet('/users/me', auth: true);
      if (mounted) {
        setState(() => _isOwner = me?['is_owner'] == true);
      }
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _channels = data ?? [];
      });
    }
  }

  Future<void> _addChannel() async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (ctx) => const _AddChannelDialog(),
    );
    if (result == null) return;
    final ok = await apiPost('/channels', result, auth: true);
    if (ok != null) {
      _showToast('Канал добавлен');
      _fetch();
    } else {
      _showToast('Ошибка добавления');
    }
  }

  Future<void> _deleteChannel(String id) async {
    final ok = await apiDelete('/channels/$id', auth: true);
    if (ok) {
      _showToast('Канал удалён');
      _fetch();
    } else {
      _showToast('Ошибка удаления');
    }
  }

  Future<void> _toggleChannel(String id, bool active) async {
    final ok = await apiPatch('/channels/$id', {'active': !active}, auth: true);
    if (ok) {
      _fetch();
    } else {
      _showToast('Ошибка изменения статуса');
    }
  }

  Future<void> _analyzeChannel(String id) async {
    _showToast('Анализирую канал...');
    final resp = await apiPost('/channels/$id/analyze', {}, auth: true);
    if (resp != null) {
      _showToast('Анализ завершён');
    } else {
      _showToast('Ошибка анализа');
    }
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: kCard),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kGold));
    }
    return Scaffold(
      backgroundColor: kBg,
      body: Column(
        children: [
          _BalanceCard(balance: widget.balance),
          Expanded(
            child: RefreshIndicator(
              color: kGold,
              onRefresh: _fetch,
              child: _channels.isEmpty
                  ? const Center(
                      child: Text('Нет каналов', style: TextStyle(color: kDim)),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: _channels.length,
                      itemBuilder: (ctx, i) => _ChannelCard(
                        channel: _channels[i],
                        isOwner: _isOwner,
                        onDelete: () =>
                            _deleteChannel(_channels[i]['id'].toString()),
                        onToggle: () => _toggleChannel(
                            _channels[i]['id'].toString(),
                            _channels[i]['active'] == true),
                        onAnalyze: () =>
                            _analyzeChannel(_channels[i]['id'].toString()),
                      ),
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: _isOwner
          ? FloatingActionButton(
              onPressed: _addChannel,
              tooltip: 'Добавить канал',
              child: const Icon(Icons.add),
            )
          : null,
    );
  }
}

class _ChannelCard extends StatelessWidget {
  final dynamic channel;
  final bool isOwner;
  final VoidCallback onDelete;
  final VoidCallback onToggle;
  final VoidCallback onAnalyze;

  const _ChannelCard({
    required this.channel,
    required this.isOwner,
    required this.onDelete,
    required this.onToggle,
    required this.onAnalyze,
  });

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> c =
        channel is Map<String, dynamic> ? channel : {};
    final name = c['name'] ?? c['title'] ?? '—';
    final active = c['active'] == true;
    final pnl = (c['daily_pnl'] as num?)?.toDouble();

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ChannelSignalsScreen(
                channelId: c['id'].toString(),
                channelName: name.toString()),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: active ? kGreen : kDim,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name.toString(),
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold)),
                  ),
                  if (isOwner) ...[
                    IconButton(
                      icon: Icon(
                          active ? Icons.pause_circle : Icons.play_circle,
                          color: kGold,
                          size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: onToggle,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.analytics_outlined,
                          color: kDim, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: onAnalyze,
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.delete_outline,
                          color: kRed, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: onDelete,
                    ),
                  ],
                ],
              ),
              if (pnl != null) ...[
                const SizedBox(height: 6),
                Text(
                  'P&L сегодня: ${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(2)}',
                  style: TextStyle(
                      color: pnl >= 0 ? kGreen : kRed, fontSize: 12),
                ),
              ],
              const SizedBox(height: 4),
              Text('Нажмите для истории сигналов',
                  style: const TextStyle(color: kDim, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _AddChannelDialog extends StatefulWidget {
  const _AddChannelDialog();

  @override
  State<_AddChannelDialog> createState() => _AddChannelDialogState();
}

class _AddChannelDialogState extends State<_AddChannelDialog> {
  final _nameCtrl = TextEditingController();
  final _urlCtrl = TextEditingController();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kCard,
      title: const Text('Добавить канал', style: TextStyle(color: kGold)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _nameCtrl,
            decoration: const InputDecoration(
              labelText: 'Название',
              labelStyle: TextStyle(color: kDim),
            ),
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'URL / Username',
              labelStyle: TextStyle(color: kDim),
            ),
            style: const TextStyle(color: Colors.white),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена', style: TextStyle(color: kDim)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, {
            'name': _nameCtrl.text,
            'url': _urlCtrl.text,
          }),
          child: const Text('Добавить', style: TextStyle(color: kGold)),
        ),
      ],
    );
  }
}

// ─── Channel Signals Screen ───────────────────────────────────────────────────
class ChannelSignalsScreen extends StatefulWidget {
  final String channelId;
  final String channelName;

  const ChannelSignalsScreen(
      {super.key, required this.channelId, required this.channelName});

  @override
  State<ChannelSignalsScreen> createState() => _ChannelSignalsScreenState();
}

class _ChannelSignalsScreenState extends State<ChannelSignalsScreen> {
  List<dynamic> _signals = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final data = await apiGetList(
        '/signals?channel=${Uri.encodeComponent(widget.channelName)}&limit=20');
    if (mounted) {
      setState(() {
        _loading = false;
        _signals = data ?? [];
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.channelName)),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: kGold))
          : _signals.isEmpty
              ? const Center(
                  child: Text('Нет сигналов', style: TextStyle(color: kDim)))
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: _signals.length,
                  itemBuilder: (ctx, i) => _SignalCard(signal: _signals[i]),
                ),
    );
  }
}

// ─── Backtest Tab ─────────────────────────────────────────────────────────────
class BacktestTab extends StatelessWidget {
  const BacktestTab({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.construction, color: kGold.withOpacity(0.5), size: 64),
          const SizedBox(height: 16),
          const Text('В разработке',
              style: TextStyle(
                  color: kGold, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Бэктест будет доступен в следующей версии',
              style: TextStyle(color: kDim)),
        ],
      ),
    );
  }
}
