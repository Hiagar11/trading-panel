import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:developer' as developer;
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:open_file/open_file.dart';
import 'package:url_launcher/url_launcher.dart';

// ─── Constants ───────────────────────────────────────────────────────────────
const int kCurrentBuild = 100;
const String kCurrentVersion = '1.6.9';
const String kApiBase = 'https://85.192.38.213:8766';
const String kGitHubRepo = 'Hiagar11/trading-panel';

const kBg = Color(0xFF080808);
const kCard = Color(0xFF101010);
const kGold = Color(0xFFD4A017);
const kGreen = Color(0xFF22D3A5);
const kRed = Color(0xFFFF4466);
const kDim = Color(0xFF6B6B6B);

// ─── Secure HTTP/WebSocket client ────────────────────────────────────────────
HttpClient? _secureDartIoClient;
http.Client _secureHttpClient = http.Client();

Future<void> _initSecureClient() async {
  try {
    final certData = await rootBundle.load('assets/certs/server.crt');
    final secCtx = SecurityContext(withTrustedRoots: true);
    secCtx.setTrustedCertificatesBytes(certData.buffer.asUint8List());
    _secureDartIoClient = HttpClient(context: secCtx);
    _secureDartIoClient!.badCertificateCallback =
        (X509Certificate cert, String host, int port) {
      // Accept our pinned self-signed cert regardless of hostname
      return cert.sha1.map((b) => b.toRadixString(16).padLeft(2, '0')).join(':').toUpperCase() ==
          'C4:AC:37:F2:7E:48:D3:BD:94:C6:6A:90:4B:0E:95:7C:7B:62:84:CC';
    };
    _secureHttpClient = IOClient(_secureDartIoClient!);
  } catch (e) {
    debugPrint('Secure client init failed, falling back to default: $e');
  }
}

// ─── Theme Customization ──────────────────────────────────────────────────────
const _kAccentPresets = [
  Color(0xFFD4A017), // Gold (default)
  Color(0xFF22D3A5), // Teal
  Color(0xFFA855F7), // Purple
  Color(0xFFF97316), // Orange
];

const _kCardPresets = [
  Color(0xFF101010), // Default
  Color(0xFF1A1A1A), // Warm
  Color(0xFF0D1117), // Cool
];

class _ThemeCustom {
  final Color accent;
  final Color cardBg;
  final bool gridView;
  const _ThemeCustom({
    this.accent = const Color(0xFFD4A017),
    this.cardBg = const Color(0xFF101010),
    this.gridView = false,
  });
}

final _themeCustom = ValueNotifier<_ThemeCustom>(const _ThemeCustom());

Future<void> _loadThemeCustom() async {
  final prefs = await SharedPreferences.getInstance();
  final accentIdx = (prefs.getInt('theme_accent') ?? 0).clamp(0, _kAccentPresets.length - 1);
  final cardIdx = (prefs.getInt('theme_card') ?? 0).clamp(0, _kCardPresets.length - 1);
  final gridView = prefs.getBool('theme_grid') ?? false;
  _themeCustom.value = _ThemeCustom(
    accent: _kAccentPresets[accentIdx],
    cardBg: _kCardPresets[cardIdx],
    gridView: gridView,
  );
}

Future<void> _saveThemeCustom(int accentIdx, int cardIdx, bool gridView) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('theme_accent', accentIdx);
  await prefs.setInt('theme_card', cardIdx);
  await prefs.setBool('theme_grid', gridView);
  _themeCustom.value = _ThemeCustom(
    accent: _kAccentPresets[accentIdx],
    cardBg: _kCardPresets[cardIdx],
    gridView: gridView,
  );
}

// ─── UI Mode ──────────────────────────────────────────────────────────────────
enum UiMode { basic, advanced }

final _uiMode = ValueNotifier<UiMode>(UiMode.advanced);

Future<void> _loadUiMode() async {
  final prefs = await SharedPreferences.getInstance();
  final val = prefs.getString('ui_mode');
  _uiMode.value = val == 'advanced' ? UiMode.advanced : UiMode.basic;
}

Future<void> _toggleUiMode() async {
  final next = _uiMode.value == UiMode.basic ? UiMode.advanced : UiMode.basic;
  _uiMode.value = next;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString('ui_mode', next.name);
}

// ─── Install channel ─────────────────────────────────────────────────────────
const _installChannel = MethodChannel('com.example.trading_panel/install');

// ─── WebSocket service ────────────────────────────────────────────────────────
enum WsStatus { offline, connecting, online, stale }

class WsSnapshot {
  final WsStatus status;
  final double balance;
  final bool watcherAlive;
  final int openPositions;
  final int? newBuild;
  final List<Map<String, dynamic>> positions;

  const WsSnapshot({
    this.status = WsStatus.offline,
    this.balance = 0,
    this.watcherAlive = false,
    this.openPositions = 0,
    this.newBuild,
    this.positions = const [],
  });

  WsSnapshot copyWith({
    WsStatus? status,
    double? balance,
    bool? watcherAlive,
    int? openPositions,
    int? newBuild,
    List<Map<String, dynamic>>? positions,
  }) =>
      WsSnapshot(
        status: status ?? this.status,
        balance: balance ?? this.balance,
        watcherAlive: watcherAlive ?? this.watcherAlive,
        openPositions: openPositions ?? this.openPositions,
        newBuild: newBuild ?? this.newBuild,
        positions: positions ?? this.positions,
      );
}

// Global WebSocket service singleton — shared by all tabs
final _globalWsService = TradingWsService();

class TradingWsService {
  final _subject = BehaviorSubject<WsSnapshot>.seeded(const WsSnapshot());

  Stream<WsSnapshot> get stream => _subject.stream;
  WsSnapshot get value => _subject.value;

  WebSocket? _ws;
  int _reconnectAttempts = 0;
  Future? _pendingReconnect;
  Timer? _pingTimer;
  Timer? _pongTimeoutTimer;
  bool _updateTriggered = false;

  void connect() {
    _pendingReconnect = null;
    _subject.add(_subject.value.copyWith(status: WsStatus.connecting));
    _doConnect();
  }

  Future<void> _doConnect() async {
    try {
      _ws = await WebSocket.connect(
        'wss://85.192.38.213:8766/ws',
        customClient: _secureDartIoClient,
      );
      _reconnectAttempts = 0;
      _startPingTimer();
      _ws!.listen(
        (data) {
          _resetPongTimer();
          final msg = jsonDecode(data as String) as Map<String, dynamic>;
          if (msg['type'] == 'pong') return;
          final prev = _subject.value;
          final rawPositions = msg['positions'];
          final posList = rawPositions is List
              ? rawPositions.whereType<Map<String, dynamic>>().toList()
              : prev.positions;
          final posCount = posList.length;
          final serverBuild = msg['build'] is int ? msg['build'] as int : null;
          final triggerUpdate = !_updateTriggered &&
              serverBuild != null &&
              serverBuild > kCurrentBuild;
          if (triggerUpdate) _updateTriggered = true;
          _subject.add(WsSnapshot(
            status: WsStatus.online,
            balance: (msg['balance'] as num?)?.toDouble() ?? prev.balance,
            watcherAlive: msg['watcher_alive'] == true,
            openPositions: posCount,
            newBuild: triggerUpdate ? serverBuild : null,
            positions: posList,
          ));
        },
        onDone: _onDisconnect,
        onError: (_) => _onDisconnect(),
      );
    } catch (_) {
      _onDisconnect();
    }
  }

  void _onDisconnect() {
    _pingTimer?.cancel();
    _pongTimeoutTimer?.cancel();
    if (!_subject.isClosed) {
      _subject.add(_subject.value.copyWith(status: WsStatus.offline));
    }
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (_pendingReconnect != null) return;
    _reconnectAttempts++;
    final delaySecs =
        [5, 10, 30, 60].elementAtOrNull(_reconnectAttempts - 1) ?? 60;
    _pendingReconnect = Future.delayed(Duration(seconds: delaySecs), () {
      _pendingReconnect = null;
      connect();
    });
  }

  /// Call on app foreground resume — cancels backoff and reconnects immediately.
  void resumeConnect() {
    _pendingReconnect = null; // cancel backoff timer (dart Future can't be cancelled, but we clear the flag)
    _reconnectAttempts = 0;
    final status = _subject.value.status;
    if (status == WsStatus.offline || status == WsStatus.stale) {
      connect();
    } else if (status == WsStatus.online) {
      // Send a ping to verify the connection is still alive
      try {
        _ws?.add(jsonEncode({'type': 'ping'}));
      } catch (_) {
        _onDisconnect();
      }
    }
  }

  void _startPingTimer() {
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      if (_ws != null && _subject.value.status == WsStatus.online) {
        try {
          _ws!.add(jsonEncode({'type': 'ping'}));
        } catch (_) {}
        _pongTimeoutTimer?.cancel();
        _pongTimeoutTimer = Timer(const Duration(seconds: 10), () {
          if (!_subject.isClosed) {
            _subject.add(_subject.value.copyWith(status: WsStatus.stale));
          }
        });
      }
    });
  }

  void _resetPongTimer() {
    _pongTimeoutTimer?.cancel();
    _pongTimeoutTimer = null;
    if (_subject.value.status == WsStatus.stale && !_subject.isClosed) {
      _subject.add(_subject.value.copyWith(status: WsStatus.online));
    }
  }

  void dispose() {
    _pingTimer?.cancel();
    _pongTimeoutTimer?.cancel();
    _pendingReconnect = null;
    _ws?.close();
    _subject.close();
  }
}

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
  HapticFeedback.heavyImpact();
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
  // Handle both tap on notification body and 'install_now' action button
  if (response.actionId == 'install_now' || response.actionId == null) {
    await OpenFile.open(payload);
  }
}

@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
}

// ─── App entry ───────────────────────────────────────────────────────────────
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _initSecureClient();
  await Firebase.initializeApp();
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  await initNotifications(onTap: _onNotificationTap);
  runApp(const TradingPanelApp());
}

class TradingPanelApp extends StatelessWidget {
  const TradingPanelApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_ThemeCustom>(
      valueListenable: _themeCustom,
      builder: (_, custom, __) => MaterialApp(
        title: 'Trading Panel',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          scaffoldBackgroundColor: kBg,
          colorScheme: ColorScheme.dark(
            primary: custom.accent,
            secondary: custom.accent,
            surface: custom.cardBg,
            background: kBg,
          ),
          appBarTheme: AppBarTheme(
            backgroundColor: kCard,
            elevation: 0,
            titleTextStyle: TextStyle(
              color: custom.accent,
              fontSize: 18,
              fontWeight: FontWeight.bold,
              letterSpacing: 1.2,
            ),
            iconTheme: IconThemeData(color: custom.accent),
          ),
          bottomNavigationBarTheme: const BottomNavigationBarThemeData(
            backgroundColor: kCard,
            selectedItemColor: kGold,
            unselectedItemColor: kDim,
            type: BottomNavigationBarType.fixed,
          ),
          cardTheme: CardThemeData(
            color: custom.cardBg,
            elevation: 0,
          ),
          textTheme: const TextTheme(
            bodyMedium: TextStyle(color: Colors.white),
            bodySmall: TextStyle(color: kDim),
          ),
          floatingActionButtonTheme: FloatingActionButtonThemeData(
            backgroundColor: custom.accent,
            foregroundColor: Colors.black,
          ),
        ),
        home: const HomeScreen(),
      ),
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
    final resp = await _secureHttpClient
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
    final resp = await _secureHttpClient
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
    final resp = await _secureHttpClient
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
    final resp = await _secureHttpClient
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
    final resp = await _secureHttpClient
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  bool _watcherAlive = false;
  double _balance = 0;
  int _openPositions = 0;
  int _selectedTab = 0;
  late final PageController _pageController = PageController();
  Timer? _statusTimer;
  Timer? _checkUpdateTimer;
  Timer? _healthTimer;
  WsStatus _wsStatus = WsStatus.offline;
  double _downloadProgress = 0.0;
  String _latestVersion = kCurrentVersion;
  bool _updateInProgress = false;
  bool _updateAvailable = false;
  bool _updateInstalled = false;
  int _availableBuild = 0;
  bool _botHealthy = false;
  int _lastSignalSecondsAgo = -1;

  TradingWsService get _wsService => _globalWsService;
  StreamSubscription<WsSnapshot>? _wsSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _globalWsService.resumeConnect();
    }
  }

  Future<void> _init() async {
    await SessionManager.load();
    await _loadUiMode();
    await _loadThemeCustom();
    await _requestPermissions();
    _fetchStatus();
    _wsService.connect();
    _wsSub = _wsService.stream.listen(_onWsSnapshot);
    // Fallback polling every 30s in case WebSocket drops and reconnect is pending
    _statusTimer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchStatus());
    // GitHub fallback update check (runs when VPS is unreachable)
    _checkUpdate();
    _checkUpdateTimer = Timer.periodic(const Duration(seconds: 20), (_) => _checkUpdate());
    _fetchHealth();
    _healthTimer = Timer.periodic(const Duration(seconds: 60), (_) => _fetchHealth());
    _setupFCM();
  }

  Future<void> _setupFCM() async {
    final messaging = FirebaseMessaging.instance;
    await messaging.requestPermission(alert: true, badge: true, sound: true);
    final token = await messaging.getToken();
    debugPrint('FCM Token: $token');
    if (token != null) {
      try {
        await _secureHttpClient.post(
          Uri.parse('$kApiBase/fcm/register'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'token': token, 'platform': 'android'}),
        );
      } catch (e) {
        debugPrint('FCM register error: $e');
      }
    }
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      if (notification != null) {
        showSignalNotification(
          notification.title ?? 'Новый сигнал',
          notification.body ?? '',
        );
      }
    });
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('Notification tapped: ${message.data}');
    });
  }

  void _onWsSnapshot(WsSnapshot snap) {
    if (!mounted) return;
    setState(() {
      _wsStatus = snap.status;
      if (snap.balance > 0) _balance = snap.balance;
      _watcherAlive = snap.watcherAlive;
      _openPositions = snap.openPositions;
    });
    if (snap.newBuild != null && !_updateInProgress && !_updateInstalled) {
      final build = snap.newBuild!;
      if (build > kCurrentBuild && !_updateAvailable) {
        setState(() { _updateAvailable = true; _availableBuild = build; });
      }
    }
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
        if (serverBuild > kCurrentBuild && !_updateInProgress && !_updateInstalled && !_updateAvailable) {
          setState(() { _updateAvailable = true; _availableBuild = serverBuild; });
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
          if (remoteBuild > kCurrentBuild && mounted && !_updateInstalled && !_updateAvailable) {
            _latestVersion = parts[0];
            setState(() { _updateAvailable = true; _availableBuild = remoteBuild; });
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

    bool installLaunched = false;
    try {
      // Использовать временную директорию — FileProvider поддерживает cache-path
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/trading_panel_update.apk');

      // Скачиваем с VPS напрямую (без redirect'ов GitHub)
      final apkUri = Uri.parse('$kApiBase/download/apk');
      final ioReq = await _secureDartIoClient!.getUrl(apkUri);
      final ioResp = await ioReq.close();
      final bytes = <int>[];
      int received = 0;
      final total = ioResp.contentLength;
      await for (final chunk in ioResp) {
        bytes.addAll(chunk);
        received += chunk.length;
        if (total > 0 && mounted) setState(() => _downloadProgress = received / total);
      }
      await file.writeAsBytes(bytes);

      // Закрыть диалог
      nav.pop();

      // Открыть APK через open_file (ACTION_VIEW + MIME type, совместимо с Android 12+)
      final result = await OpenFile.open(file.path);
      if (result.type == ResultType.done) {
        installLaunched = true;
        _updateInstalled = true;
        _updateAvailable = false;
        _checkUpdateTimer?.cancel();
        _checkUpdateTimer = null;
      } else {
        scaffoldMsg.showSnackBar(SnackBar(
          content: Text('Ошибка установщика: ${result.message}'),
          backgroundColor: Colors.red.shade900,
          duration: const Duration(seconds: 10),
        ));
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
      if (mounted) setState(() => _downloadProgress = 0.0);
      // Не сбрасываем флаг если установщик запущен — пусть app заменится
      if (!installLaunched) _updateInProgress = false;
    }
  }

  Future<void> _showInstallNotification(String apkPath) async {
    final androidDetails = AndroidNotificationDetails(
      'update_channel',
      'Обновления',
      channelDescription: 'Уведомления об обновлениях приложения',
      importance: Importance.max,
      priority: Priority.high,
      ongoing: false,
      autoCancel: true,
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction(
          'install_now',
          'Установить',
          showsUserInterface: true,
        ),
      ],
    );
    final details = NotificationDetails(android: androidDetails);
    await _notificationsPlugin.show(
      999,
      'Обновление готово',
      'Trading Panel v$_latestVersion готова к установке',
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
    final statusMsg = start ? 'Запуск наблюдателя...' : 'Остановка наблюдателя...';
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        content: Row(
          children: [
            const CircularProgressIndicator(color: kGold),
            const SizedBox(width: 16),
            Expanded(child: Text(statusMsg, style: const TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
    await apiPost('/watcher', {'action': action});
    if (mounted) {
      Navigator.of(context).pop();
    }
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
    WidgetsBinding.instance.removeObserver(this);
    _statusTimer?.cancel();
    _checkUpdateTimer?.cancel();
    _healthTimer?.cancel();
    _wsSub?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onLongPress: _showDevMenu,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('TRADING PANEL'),
                  Text('v$kCurrentVersion', style: TextStyle(fontSize: 11, color: kDim)),
                ],
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  color: kGold.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: kGold.withOpacity(0.5)),
                ),
                child: const Text('PAPER',
                    style: TextStyle(
                        color: kGold, fontSize: 9, fontWeight: FontWeight.bold,
                        letterSpacing: 0.5)),
              ),
            ],
          ),
        ),
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
                    color: _wsStatus == WsStatus.online
                        ? Colors.green
                        : _wsStatus == WsStatus.stale
                            ? Colors.amber
                            : Colors.red,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  _wsStatus == WsStatus.online
                      ? 'ONLINE'
                      : _wsStatus == WsStatus.stale
                          ? 'STALE'
                          : 'OFFLINE',
                  style: TextStyle(
                    color: _wsStatus == WsStatus.online
                        ? Colors.green
                        : _wsStatus == WsStatus.stale
                            ? Colors.amber
                            : Colors.red,
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
          ValueListenableBuilder<UiMode>(
            valueListenable: _uiMode,
            builder: (_, mode, __) => mode == UiMode.advanced
                ? _WatcherControlWidget(
                    alive: _watcherAlive,
                    onPlay: () => _setWatcher(true),
                    onPause: () => _setWatcher(false),
                  )
                : const SizedBox.shrink(),
          ),
          IconButton(
            icon: const Icon(Icons.account_circle),
            onPressed: () => _showProfileSheet(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_updateAvailable && !_updateInProgress)
            GestureDetector(
              onTap: () {
                setState(() { _updateAvailable = false; _updateInProgress = true; });
                _downloadAndInstall('');
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: kGold.withOpacity(0.12),
                child: Row(
                  children: [
                    const Icon(Icons.system_update_alt, color: kGold, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Обновление $_availableBuild доступно',
                        style: const TextStyle(color: kGold, fontSize: 13),
                      ),
                    ),
                    const Text('Установить',
                        style: TextStyle(
                            color: kGold,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, color: kGold, size: 18),
                  ],
                ),
              ),
            ),
          if (_downloadProgress > 0 && _downloadProgress < 1.0)
            LinearProgressIndicator(
              value: _downloadProgress,
              minHeight: 3,
              backgroundColor: Colors.grey[800],
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
            ),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (i) => setState(() => _selectedTab = i),
              children: [
                ChannelsTab(balance: _balance),
                const PositionsTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedTab,
        onTap: (i) {
          setState(() => _selectedTab = i);
          _pageController.jumpToPage(i);
        },
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.view_list),
            label: 'Каналы',
          ),
          BottomNavigationBarItem(
            icon: Badge(
              isLabelVisible: _openPositions > 0,
              label: Text('$_openPositions'),
              child: const Icon(Icons.show_chart),
            ),
            label: 'Позиции',
          ),
        ],
      ),
    );
  }

  void _showDevMenu() {
    showDialog(context: context, builder: (_) => const _DevMenuDialog());
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
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
        ),
        if (!alive)
          const Text('Новые сигналы на паузе',
              style: TextStyle(color: kDim, fontSize: 11)),
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
    if (!mounted) return;
    setState(() => _loading = true);
    final resp = await apiPost('/users/$userId/login', {'pin': pin});
    if (!mounted) return;
    setState(() => _loading = false);
    if (resp != null && resp['token'] != null) {
      final name = _users
          .firstWhere((u) => u['id'].toString() == userId,
              orElse: () => {'name': 'User'})['name']
          .toString();
      await SessionManager.save(resp['token'], userId, name);
      if (!mounted) return;
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
    if (!mounted) return;
    setState(() => _loading = true);
    final resp = await apiPost('/users', result);
    if (!mounted) return;
    setState(() => _loading = false);
    if (resp != null) {
      _showToast('Профиль создан');
      _loadUsers();
    } else {
      _showToast('Ошибка создания');
    }
  }

  Future<void> _logout() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        content: const Row(
          children: [
            CircularProgressIndicator(color: kGold),
            SizedBox(width: 16),
            Expanded(child: Text('Выход...', style: TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
    if (SessionManager.userId != null) {
      await apiPost('/users/${SessionManager.userId}/logout', {},
          auth: true);
    }
    await SessionManager.clear();
    if (mounted) {
      Navigator.of(context).pop();
    }
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
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Профиль',
                  style: TextStyle(
                      color: kGold, fontSize: 18, fontWeight: FontWeight.bold)),
              GestureDetector(
                onTap: () => showDialog(
                  context: context,
                  builder: (_) => const _ThemePanelDialog(),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: kGold.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kGold.withOpacity(0.4), width: 0.5),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: const [
                      Icon(Icons.palette_outlined, color: kGold, size: 14),
                      SizedBox(width: 5),
                      Text('Вид', style: TextStyle(color: kGold, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ],
          ),
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

// ─── Dev Menu Dialog ──────────────────────────────────────────────────────────
class _DevMenuDialog extends StatefulWidget {
  const _DevMenuDialog();
  @override
  State<_DevMenuDialog> createState() => _DevMenuDialogState();
}

class _DevMenuDialogState extends State<_DevMenuDialog> {
  Timer? _refreshTimer;
  int _rssBytes = 0;
  int _maxRssBytes = 0;
  int _refreshCount = 0;
  int _prevRss = 0;
  double _gcPressure = 0.0;

  @override
  void initState() {
    super.initState();
    _prevRss = ProcessInfo.currentRss;
    _refresh();
    _refreshTimer = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  void _refresh() {
    if (!mounted) return;
    final cur = ProcessInfo.currentRss;
    final max = ProcessInfo.maxRss;
    // GC pressure: estimate by how much RSS dropped vs peak (higher = more GC activity)
    final dropped = _prevRss > cur ? _prevRss - cur : 0;
    final pressure = max > 0 ? (dropped / max * 100.0).clamp(0.0, 100.0) : 0.0;
    setState(() {
      _rssBytes = cur;
      _maxRssBytes = max;
      _gcPressure = pressure;
      _prevRss = cur;
      _refreshCount++;
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  String _fmtBytes(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Widget _row(String label, String value, {Color? valueColor}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: kDim, fontSize: 13)),
            Text(value,
                style: TextStyle(
                    color: valueColor ?? Colors.white, fontSize: 13)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final pressureColor = _gcPressure > 20
        ? kRed
        : _gcPressure > 5
            ? Colors.amber
            : kGreen;
    return AlertDialog(
      backgroundColor: kCard,
      title: Row(
        children: [
          const Icon(Icons.memory, color: kGold, size: 18),
          const SizedBox(width: 8),
          const Text('Dev Menu', style: TextStyle(color: kGold, fontSize: 16)),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _row('Build', '#$kCurrentBuild'),
          _row('Version', kCurrentVersion),
          const Divider(color: kDim, height: 16),
          const Text('Memory (RSS)',
              style: TextStyle(color: kGold, fontSize: 11, letterSpacing: 0.8)),
          const SizedBox(height: 4),
          _row('Current RSS', _fmtBytes(_rssBytes)),
          _row('Peak RSS', _fmtBytes(_maxRssBytes)),
          _row('GC Pressure', '${_gcPressure.toStringAsFixed(1)}%',
              valueColor: pressureColor),
          const SizedBox(height: 4),
          Text('Refreshed $_refreshCount× (every 2s)',
              style: const TextStyle(color: kDim, fontSize: 10)),
          const SizedBox(height: 4),
          Text('Note: --profile mode adds heap timeline in DevTools',
              style: const TextStyle(color: kDim, fontSize: 10)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            // Post a timeline event visible in --profile DevTools
            developer.Timeline.startSync('manual_gc_hint');
            developer.Timeline.finishSync();
            _refresh();
          },
          child: const Text('Refresh', style: TextStyle(color: kDim)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close', style: TextStyle(color: kGold)),
        ),
      ],
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

// ─── Theme Panel Dialog ───────────────────────────────────────────────────────
class _ThemePanelDialog extends StatefulWidget {
  const _ThemePanelDialog();
  @override
  State<_ThemePanelDialog> createState() => _ThemePanelDialogState();
}

class _ThemePanelDialogState extends State<_ThemePanelDialog> {
  late int _accentIdx;
  late int _cardIdx;
  late bool _gridView;

  static const _accentLabels = ['Gold', 'Teal', 'Purple', 'Orange'];
  static const _cardLabels = ['Default', 'Warm', 'Cool'];

  @override
  void initState() {
    super.initState();
    final cur = _themeCustom.value;
    _accentIdx = _kAccentPresets.indexOf(cur.accent).clamp(0, _kAccentPresets.length - 1);
    _cardIdx = _kCardPresets.indexOf(cur.cardBg).clamp(0, _kCardPresets.length - 1);
    _gridView = cur.gridView;
  }

  Widget _swatch(Color color, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.transparent,
            width: selected ? 2.5 : 0,
          ),
          boxShadow: selected
              ? [BoxShadow(color: color.withOpacity(0.5), blurRadius: 8, spreadRadius: 1)]
              : null,
        ),
      ),
    );
  }

  Widget _cardSwatch(Color bg, String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        width: 60,
        height: 36,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? Colors.white : kDim,
            width: selected ? 2 : 0.5,
          ),
        ),
        alignment: Alignment.center,
        child: Text(label,
            style: TextStyle(
                color: selected ? Colors.white : kDim,
                fontSize: 10,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: kCard,
      title: Row(children: [
        const Icon(Icons.palette_outlined, color: kGold, size: 18),
        const SizedBox(width: 8),
        const Text('Внешний вид', style: TextStyle(color: kGold, fontSize: 16)),
      ]),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Акцентный цвет',
              style: TextStyle(color: kDim, fontSize: 11, letterSpacing: 0.8)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(_kAccentPresets.length, (i) => Column(
              children: [
                _swatch(_kAccentPresets[i], _accentIdx == i,
                    () => setState(() => _accentIdx = i)),
                const SizedBox(height: 4),
                Text(_accentLabels[i],
                    style: const TextStyle(color: kDim, fontSize: 9)),
              ],
            )),
          ),
          const SizedBox(height: 16),
          const Text('Фон карточки',
              style: TextStyle(color: kDim, fontSize: 11, letterSpacing: 0.8)),
          const SizedBox(height: 10),
          Row(
            children: List.generate(_kCardPresets.length, (i) => Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _cardSwatch(_kCardPresets[i], _cardLabels[i], _cardIdx == i,
                  () => setState(() => _cardIdx = i)),
            )),
          ),
          const SizedBox(height: 16),
          const Text('Вид списка сигналов',
              style: TextStyle(color: kDim, fontSize: 11, letterSpacing: 0.8)),
          const SizedBox(height: 8),
          Row(
            children: [
              _viewToggle(Icons.view_list, 'Лента', !_gridView,
                  () => setState(() => _gridView = false)),
              const SizedBox(width: 8),
              _viewToggle(Icons.grid_view, 'Сетка', _gridView,
                  () => setState(() => _gridView = true)),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена', style: TextStyle(color: kDim)),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            _saveThemeCustom(_accentIdx, _cardIdx, _gridView);
          },
          child: const Text('Применить', style: TextStyle(color: kGold)),
        ),
      ],
    );
  }

  Widget _viewToggle(IconData icon, String label, bool selected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? kGold.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: selected ? kGold : kDim, width: selected ? 1.5 : 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: selected ? kGold : kDim, size: 16),
            const SizedBox(width: 6),
            Text(label,
                style: TextStyle(
                    color: selected ? kGold : kDim,
                    fontSize: 12,
                    fontWeight: selected ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }
}

// ─── Signals Tab ──────────────────────────────────────────────────────────────
enum _SignalSort { newest, pair, pnl }
enum _FilterDir { all, longBuy, shortSell }
enum _FilterStatus { all, tp, sl, open }
enum _FilterTime { all, h1, h24, d7 }

class SignalsTab extends StatefulWidget {
  final void Function(Map<String, dynamic>) onNewSignal;
  const SignalsTab({super.key, required this.onNewSignal});

  @override
  State<SignalsTab> createState() => _SignalsTabState();
}

class _SignalsTabState extends State<SignalsTab> {
  List<dynamic> _signals = [];
  final Set<String> _archivedIds = {};
  bool _loading = true;
  String? _error;
  Timer? _timer;
  String? _lastId;
  _SignalSort _sortMode = _SignalSort.newest;
  final TextEditingController _searchCtrl = TextEditingController();
  bool _showFilters = false;
  _FilterDir _filterDir = _FilterDir.all;
  _FilterStatus _filterStatus = _FilterStatus.all;
  _FilterTime _filterTime = _FilterTime.all;

  @override
  void initState() {
    super.initState();
    _fetch();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _fetch());
    _searchCtrl.addListener(() { if (mounted) setState(() {}); });
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
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _hasActiveFilter =>
      _filterDir != _FilterDir.all ||
      _filterStatus != _FilterStatus.all ||
      _filterTime != _FilterTime.all;

  List<dynamic> get _sortedSignals {
    final list = List<dynamic>.from(_signals);
    switch (_sortMode) {
      case _SignalSort.newest:
        break; // API already returns newest first
      case _SignalSort.pair:
        list.sort((a, b) {
          final ma = a is Map ? a : <String, dynamic>{};
          final mb = b is Map ? b : <String, dynamic>{};
          final pa = (ma['pair'] ?? ma['symbol'] ?? '').toString();
          final pb = (mb['pair'] ?? mb['symbol'] ?? '').toString();
          return pa.compareTo(pb);
        });
      case _SignalSort.pnl:
        list.sort((a, b) {
          final ma = a is Map ? a : <String, dynamic>{};
          final mb = b is Map ? b : <String, dynamic>{};
          final pa = ma['pnl'] ?? ma['profit'] ?? ma['profit_pct'] ?? 0;
          final pb = mb['pnl'] ?? mb['profit'] ?? mb['profit_pct'] ?? 0;
          final da = pa is num ? pa.toDouble() : double.tryParse(pa.toString()) ?? 0;
          final db = pb is num ? pb.toDouble() : double.tryParse(pb.toString()) ?? 0;
          return db.compareTo(da); // highest P&L first
        });
    }
    return list;
  }

  String _signalKey(dynamic raw) {
    final s = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
    return (s['id'] ?? s['timestamp'] ?? s['created_at'] ?? s['time'] ?? identityHashCode(raw)).toString();
  }

  List<dynamic> get _filteredSignals {
    final sorted = _sortedSignals;
    final query = _searchCtrl.text.trim().toLowerCase();
    final now = DateTime.now().toUtc();
    return sorted.where((raw) {
      if (_archivedIds.contains(_signalKey(raw))) return false;
      final s = raw is Map<String, dynamic> ? raw : <String, dynamic>{};
      if (query.isNotEmpty) {
        final pair = (s['pair'] ?? s['symbol'] ?? '').toString().toLowerCase();
        if (!pair.contains(query)) return false;
      }
      if (_filterDir != _FilterDir.all) {
        final dir = (s['direction'] ?? s['side'] ?? s['type'] ?? '').toString().toUpperCase();
        final isLong = dir.contains('LONG') || dir.contains('BUY');
        final isShort = dir.contains('SHORT') || dir.contains('SELL');
        if (_filterDir == _FilterDir.longBuy && !isLong) return false;
        if (_filterDir == _FilterDir.shortSell && !isShort) return false;
      }
      if (_filterStatus != _FilterStatus.all) {
        final outcome = (s['outcome'] ?? s['status'] ?? s['result'] ?? '').toString().toLowerCase();
        final isTp = outcome.contains('tp') || outcome == 'win' || outcome == 'profit';
        final isSl = outcome.contains('sl') || outcome == 'loss' || outcome == 'stop';
        if (_filterStatus == _FilterStatus.tp && !isTp) return false;
        if (_filterStatus == _FilterStatus.sl && !isSl) return false;
        if (_filterStatus == _FilterStatus.open && (isTp || isSl)) return false;
      }
      if (_filterTime != _FilterTime.all) {
        final ts = s['timestamp'] ?? s['created_at'] ?? s['time'];
        if (ts == null) return false;
        DateTime? dt;
        try {
          final rawTs = ts.toString();
          dt = DateTime.tryParse(rawTs);
          if (dt == null) {
            final epoch = double.tryParse(rawTs);
            if (epoch != null) {
              dt = DateTime.fromMillisecondsSinceEpoch(
                  epoch > 1e10 ? epoch.toInt() : (epoch * 1000).toInt());
            }
          }
        } catch (_) {}
        if (dt == null) return false;
        final age = now.difference(dt.toUtc());
        if (_filterTime == _FilterTime.h1 && age.inMinutes >= 60) return false;
        if (_filterTime == _FilterTime.h24 && age.inHours >= 24) return false;
        if (_filterTime == _FilterTime.d7 && age.inDays >= 7) return false;
      }
      return true;
    }).toList();
  }

  Widget _buildSortChip(String label, _SignalSort mode, IconData icon) {
    final active = _sortMode == mode;
    return GestureDetector(
      onTap: () => setState(() => _sortMode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? kGold.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: active ? kGold : kDim, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: active ? kGold : kDim),
            const SizedBox(width: 4),
            Text(label,
                style: TextStyle(
                    color: active ? kGold : kDim,
                    fontSize: 12,
                    fontWeight:
                        active ? FontWeight.bold : FontWeight.normal)),
          ],
        ),
      ),
    );
  }

  Widget _buildSortBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 8),
      child: Row(
        children: [
          _buildSortChip('Новые', _SignalSort.newest, Icons.access_time),
          const SizedBox(width: 6),
          _buildSortChip('Пара', _SignalSort.pair, Icons.sort_by_alpha),
          const SizedBox(width: 6),
          _buildSortChip('P&L', _SignalSort.pnl, Icons.trending_up),
        ],
      ),
    );
  }

  Widget _buildFChip<T>(String label, T val, T current, Color activeColor, void Function(T) onTap) {
    final active = val == current;
    return GestureDetector(
      onTap: () => setState(() => onTap(val)),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        margin: const EdgeInsets.only(right: 5),
        decoration: BoxDecoration(
          color: active ? activeColor.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: active ? activeColor : kDim, width: 0.5),
        ),
        child: Text(label,
            style: TextStyle(
                color: active ? activeColor : kDim,
                fontSize: 11,
                fontWeight: active ? FontWeight.bold : FontWeight.normal)),
      ),
    );
  }

  Widget _buildFilterPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Row(children: [
          const Text('Напр:', style: TextStyle(color: kDim, fontSize: 11)),
          const SizedBox(width: 6),
          _buildFChip('Все', _FilterDir.all, _filterDir, kGold, (v) => _filterDir = v),
          _buildFChip('LONG', _FilterDir.longBuy, _filterDir, kGreen, (v) => _filterDir = v),
          _buildFChip('SHORT', _FilterDir.shortSell, _filterDir, kRed, (v) => _filterDir = v),
        ]),
        const SizedBox(height: 5),
        Row(children: [
          const Text('Статус:', style: TextStyle(color: kDim, fontSize: 11)),
          const SizedBox(width: 6),
          _buildFChip('Все', _FilterStatus.all, _filterStatus, kGold, (v) => _filterStatus = v),
          _buildFChip('TP', _FilterStatus.tp, _filterStatus, kGreen, (v) => _filterStatus = v),
          _buildFChip('SL', _FilterStatus.sl, _filterStatus, kRed, (v) => _filterStatus = v),
          _buildFChip('Откр', _FilterStatus.open, _filterStatus, kDim, (v) => _filterStatus = v),
        ]),
        const SizedBox(height: 5),
        Row(children: [
          const Text('Период:', style: TextStyle(color: kDim, fontSize: 11)),
          const SizedBox(width: 6),
          _buildFChip('Все', _FilterTime.all, _filterTime, kGold, (v) => _filterTime = v),
          _buildFChip('1ч', _FilterTime.h1, _filterTime, kGold, (v) => _filterTime = v),
          _buildFChip('24ч', _FilterTime.h24, _filterTime, kGold, (v) => _filterTime = v),
          _buildFChip('7д', _FilterTime.d7, _filterTime, kGold, (v) => _filterTime = v),
        ]),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 36,
                  decoration: BoxDecoration(
                    color: const Color(0xFF101010),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: kDim, width: 0.5),
                  ),
                  child: TextField(
                    controller: _searchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      hintText: 'Поиск по паре…',
                      hintStyle: const TextStyle(color: kDim, fontSize: 13),
                      prefixIcon: const Icon(Icons.search, color: kDim, size: 18),
                      suffixIcon: _searchCtrl.text.isNotEmpty
                          ? GestureDetector(
                              onTap: () => setState(() => _searchCtrl.clear()),
                              child: const Icon(Icons.close, color: kDim, size: 16),
                            )
                          : null,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      border: InputBorder.none,
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => setState(() => _showFilters = !_showFilters),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _hasActiveFilter
                        ? kGold.withOpacity(0.18)
                        : const Color(0xFF101010),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: _hasActiveFilter ? kGold : kDim, width: 0.5),
                  ),
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Icon(Icons.tune,
                          size: 18,
                          color: _hasActiveFilter ? kGold : kDim),
                      if (_hasActiveFilter)
                        Positioned(
                          top: 5,
                          right: 5,
                          child: Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                                color: kGold, shape: BoxShape.circle),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (_showFilters) _buildFilterPanel(),
        ],
      ),
    );
  }

  Widget _buildListHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSearchBar(),
        _buildSortBar(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: kGold));
    }
    return ValueListenableBuilder<_ThemeCustom>(
      valueListenable: _themeCustom,
      builder: (_, custom, __) => RefreshIndicator(
        color: kGold,
        onRefresh: () async {
          setState(() => _loading = false);
          await _fetch();
        },
        child: _buildContent(custom.gridView),
      ),
    );
  }

  Widget _buildContent(bool gridView) {
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
        padding: const EdgeInsets.all(8),
        children: [
          _buildListHeader(),
          const SizedBox(
            height: 260,
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
    final filtered = _filteredSignals;
    if (filtered.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(8),
        children: [
          _buildListHeader(),
          const SizedBox(height: 60),
          const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search_off, color: kDim, size: 40),
                SizedBox(height: 8),
                Text('Нет совпадений', style: TextStyle(color: kDim)),
                SizedBox(height: 4),
                Text('Измените фильтр или поиск',
                    style: TextStyle(color: kDim, fontSize: 12)),
              ],
            ),
          ),
        ],
      );
    }
    if (gridView) {
      return CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: _buildListHeader(),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.all(8),
            sliver: SliverGrid(
              delegate: SliverChildBuilderDelegate(
                (ctx, i) => SignalCard(signal: filtered[i]),
                childCount: filtered.length,
              ),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 6,
                mainAxisSpacing: 6,
                childAspectRatio: 0.78,
              ),
            ),
          ),
        ],
      );
    }
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.all(8),
      itemCount: filtered.length + 1,
      itemBuilder: (ctx, i) {
        if (i == 0) return _buildListHeader();
        final sig = filtered[i - 1];
        final key = _signalKey(sig);
        return Dismissible(
          key: ValueKey(key),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 20),
            margin: const EdgeInsets.symmetric(vertical: 4),
            decoration: BoxDecoration(
              color: kRed.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.archive_outlined, color: kRed, size: 24),
          ),
          onDismissed: (_) {
            setState(() => _archivedIds.add(key));
            ScaffoldMessenger.of(ctx).showSnackBar(
              SnackBar(
                backgroundColor: const Color(0xFF1A1A1A),
                duration: const Duration(seconds: 5),
                content: const Text('Сигнал скрыт',
                    style: TextStyle(color: Colors.white)),
                action: SnackBarAction(
                  label: 'Отмена',
                  textColor: kGold,
                  onPressed: () {
                    setState(() => _archivedIds.remove(key));
                  },
                ),
              ),
            );
          },
          child: SignalCard(signal: sig),
        );
      },
    );
  }
}

String _relativeTime(dynamic ts) {
  if (ts == null) return '';
  DateTime? dt;
  try {
    final raw = ts.toString();
    dt = DateTime.tryParse(raw);
    if (dt == null) {
      final epoch = double.tryParse(raw);
      if (epoch != null) {
        dt = DateTime.fromMillisecondsSinceEpoch(
            epoch > 1e10 ? epoch.toInt() : (epoch * 1000).toInt());
      }
    }
  } catch (_) {}
  if (dt == null) return ts.toString();
  final diff = DateTime.now().toUtc().difference(dt.toUtc()).abs();
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  return '${diff.inDays}d ago';
}

class SignalCard extends StatefulWidget {
  final dynamic signal;
  final bool showPnlAlways;
  const SignalCard({required this.signal, this.showPnlAlways = false});

  @override
  State<SignalCard> createState() => _SignalCardState();
}

class _SignalCardState extends State<SignalCard> {
  Timer? _relTimer;

  @override
  void initState() {
    super.initState();
    _relTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _relTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> s =
        widget.signal is Map<String, dynamic> ? widget.signal : {};
    final pairRaw = (s['pair'] ?? s['symbol'] ?? s['channel'] ?? '—').toString();
    final pair = pairRaw.replaceAll(RegExp(r'\s*\(\d+\)\s*'), '').trim();
    final direction = (s['direction'] ?? s['side'] ?? s['type'] ?? '')
        .toString()
        .toUpperCase();
    final price = s['price'] ?? s['entry'] ?? s['entry_price'];
    final sl = s['sl'] ?? s['stop_loss'];
    final tp = s['tp'] ?? s['take_profit'];
    final ts = s['timestamp'] ?? s['created_at'] ?? s['time'];
    final relTime = _relativeTime(ts);
    final isLong = direction.contains('LONG') || direction.contains('BUY');
    final isShort = direction.contains('SHORT') || direction.contains('SELL');
    final dirColor = isLong
        ? kGreen
        : isShort
            ? kRed
            : kDim;
    final pnlRaw = s['pnl'] ?? s['profit'] ?? s['profit_pct'];
    final pnlVal = pnlRaw is num
        ? pnlRaw.toDouble()
        : double.tryParse(pnlRaw?.toString() ?? '');

    return GestureDetector(
      onTap: () => _showSignalDetail(context, s),
      onLongPress: () {
        Clipboard.setData(ClipboardData(text: pair.toString()));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Скопировано: $pair'),
            duration: const Duration(seconds: 2),
            behavior: SnackBarBehavior.floating,
          ),
        );
      },
      child: Card(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(pair,
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
                  if (sl != null)
                    _InfoChip('SL', sl.toString(), kRed),
                  if (tp != null)
                    _InfoChip('TP', tp.toString(), kGreen),
                ],
              ),
              if (pnlVal != null || widget.showPnlAlways) ...[
                const SizedBox(height: 4),
                Text(
                  pnlVal != null
                      ? 'P&L: ${pnlVal >= 0 ? '+' : ''}\$${pnlVal.toStringAsFixed(2)}'
                      : 'P&L: —',
                  style: TextStyle(
                    color: pnlVal != null
                        ? (pnlVal > 0 ? kGreen : pnlVal < 0 ? kRed : kDim)
                        : kDim,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (ts != null) ...[
                const SizedBox(height: 4),
                Text(relTime,
                    style: const TextStyle(
                        color: kGold, fontSize: 11, fontWeight: FontWeight.w500)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

void _showSignalDetail(BuildContext context, Map<String, dynamic> s) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => SignalDetailSheet(signal: s),
  );
}

class SignalDetailSheet extends StatelessWidget {
  final Map<String, dynamic> signal;
  const SignalDetailSheet({required this.signal});

  @override
  Widget build(BuildContext context) {
    final s = signal;
    final pair = s['pair'] ?? s['symbol'] ?? s['channel'] ?? '—';
    final direction =
        (s['direction'] ?? s['side'] ?? s['type'] ?? '').toString().toUpperCase();
    final price = s['price'] ?? s['entry'] ?? s['entry_price'];
    final sl = s['sl'] ?? s['stop_loss'];
    final tp = s['tp'] ?? s['take_profit'];
    final ts = s['timestamp'] ?? s['created_at'] ?? s['time'];
    final channelName =
        s['channel_title'] ?? s['channel_name'] ?? s['channel'] ?? '—';
    final outcome = s['outcome'] ?? s['status'] ?? s['result'];
    final relTime = _relativeTime(ts);
    final isLong = direction.contains('LONG') || direction.contains('BUY');
    final isShort = direction.contains('SHORT') || direction.contains('SELL');
    final dirColor = isLong
        ? kGreen
        : isShort
            ? kRed
            : kDim;

    const knownKeys = {
      'pair', 'symbol', 'channel', 'direction', 'side', 'type',
      'price', 'entry', 'entry_price', 'sl', 'stop_loss', 'tp', 'take_profit',
      'timestamp', 'created_at', 'time', 'channel_title', 'channel_name',
      'outcome', 'status', 'result', 'id',
    };
    final extraFields =
        s.entries.where((e) => !knownKeys.contains(e.key)).toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (_, scrollCtrl) => Container(
        decoration: const BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: kDim.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 8),
              child: Row(
                children: [
                  Text(pair.toString(),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 18)),
                  const SizedBox(width: 8),
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
                  _OutcomeBadge(outcome: outcome?.toString()),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, color: kDim),
                    onPressed: () => Navigator.pop(context),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            const Divider(color: kDim, height: 1),
            Expanded(
              child: ListView(
                controller: scrollCtrl,
                padding: const EdgeInsets.all(16),
                children: [
                  _DetailRow('Вход', price?.toString() ?? '—', Colors.white),
                  _DetailRow('TP', tp?.toString() ?? '—', kGreen),
                  _DetailRow('SL', sl?.toString() ?? '—', kRed),
                  if (ts != null) ...[
                    _DetailRow('Прошло', relTime, kGold),
                    _DetailRow('Дата', ts.toString(), kDim),
                  ],
                  _DetailRow('Канал', channelName.toString(), kDim),
                  if (extraFields.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text('Дополнительно',
                        style: TextStyle(
                            color: kDim, fontSize: 11, letterSpacing: 0.8)),
                    const SizedBox(height: 8),
                    ...extraFields.map((e) =>
                        _DetailRow(e.key, e.value?.toString() ?? '—', kDim)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _DetailRow(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(label,
                style: const TextStyle(color: kDim, fontSize: 13)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
                maxLines: 2),
          ),
        ],
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
      return const SizedBox.shrink();
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
  double _drawdown = 0;
  double _dailyPnl = 0;
  int _tradeCount = 0;
  List<double> _equityCurve = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;
  Timer? _fundingTimer;
  Map<String, double> _fundingRates = {};
  StreamSubscription<WsSnapshot>? _wsSub;

  @override
  void initState() {
    super.initState();
    _fetch();
    _fetchFunding();
    // Live positions from WebSocket — no polling needed
    _wsSub = _globalWsService.stream.listen((snap) {
      if (!mounted) return;
      if (snap.positions.isNotEmpty || _positions.isNotEmpty) {
        setState(() {
          _positions = snap.positions;
          _balance = snap.balance > 0 ? snap.balance : _balance;
          _loading = false;
        });
      }
    });
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _fetch());
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
    final equityData = await apiGetList('/stats/equity_curve');
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
          _drawdown = (balData['drawdown_pct'] as num?)?.toDouble() ?? _drawdown;
        }
        if (statsData != null) {
          _dailyPnl = (statsData['pnl'] as num?)?.toDouble() ?? _dailyPnl;
          _tradeCount = (statsData['trade_count'] as num?)?.toInt() ?? _tradeCount;
        }
        if (equityData != null && equityData.isNotEmpty) {
          _equityCurve = equityData
              .map((e) => (e is Map) ? (e['cumulative'] as num?)?.toDouble() : null)
              .whereType<double>()
              .toList();
        }
      });
    }
  }

  Future<void> _closePosition(String id) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        content: const Row(
          children: [
            CircularProgressIndicator(color: kGold),
            SizedBox(width: 16),
            Expanded(child: Text('Закрытие позиции...', style: TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
    final ok = await apiDelete('/positions/$id', auth: true);
    if (mounted) {
      Navigator.of(context).pop();
      if (ok) {
        _showToast('Позиция закрыта');
        _fetch();
      } else {
        _showToast('Ошибка закрытия позиции');
      }
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
    _wsSub?.cancel();
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
          if (_drawdown > 0) ...[
            const SizedBox(height: 8),
            _DrawdownBar(drawdownPct: _drawdown),
          ],
          if (_equityCurve.length >= 2) ...[
            const SizedBox(height: 8),
            _EquityCurveCard(points: _equityCurve),
          ],
          const SizedBox(height: 12),
          _PortfolioDonutChart(positions: _positions),
          const Text('Открытые позиции',
              style: TextStyle(
                  color: kDim, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (_error != null && _positions.isEmpty)
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

String _formatPnl(double v) {
  final sign = v >= 0 ? '+' : '';
  if (v.abs() >= 1000) return '$sign\$${v.toStringAsFixed(0)}';
  if (v.abs() >= 10) return '$sign\$${v.toStringAsFixed(1)}';
  return '$sign\$${v.toStringAsFixed(2)}';
}

String _formatPrice(dynamic raw) {
  final v = double.tryParse(raw.toString());
  if (v == null) return raw.toString();
  if (v >= 1000) return v.toStringAsFixed(2);
  if (v >= 1) return v.toStringAsFixed(4);
  if (v >= 0.01) return v.toStringAsFixed(5);
  return v.toStringAsFixed(6);
}

// ─── Portfolio Donut Chart ────────────────────────────────────────────────────
class _PortfolioDonutChart extends StatefulWidget {
  final List<dynamic> positions;
  const _PortfolioDonutChart({required this.positions});

  @override
  State<_PortfolioDonutChart> createState() => _PortfolioDonutChartState();
}

class _PortfolioDonutChartState extends State<_PortfolioDonutChart>
    with SingleTickerProviderStateMixin {
  int _touchedIndex = -1;
  late AnimationController _glowCtrl;

  @override
  void initState() {
    super.initState();
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _glowCtrl.dispose();
    super.dispose();
  }

  // Vibrant gradient pairs: [dark, bright]
  static const _gradients = [
    [Color(0xFFB8860B), Color(0xFFFFD700)], // deep gold → bright gold
    [Color(0xFF0F9B8E), Color(0xFF43E8D8)], // deep teal → cyan
    [Color(0xFF5B21B6), Color(0xFFA78BFA)], // deep violet → lavender
    [Color(0xFFB45309), Color(0xFFFBBF24)], // amber dark → amber bright
    [Color(0xFF9D174D), Color(0xFFF472B6)], // rose dark → pink bright
    [Color(0xFF1D4ED8), Color(0xFF60A5FA)], // blue dark → sky
  ];

  static String _cleanPair(String pair) =>
      pair.replaceAll('USDT', '').replaceAll('/', '').trim();

  @override
  Widget build(BuildContext context) {
    if (widget.positions.isEmpty) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _glowCtrl,
      builder: (context, _) => _buildChart(context),
    );
  }

  Widget _buildChart(BuildContext context) {
    // Build per-pair data
    final Map<String, double> notional = {};
    final Map<String, String> pairSide = {};
    final Map<String, String> pairChannel = {};
    final Map<String, double> pairPnl = {};
    double totalPnl = 0.0;

    for (final p in widget.positions) {
      final pair = (p['pair'] ?? p['symbol'] ?? 'UNKNOWN').toString();
      final qty = ((p['qty'] ?? p['quantity'] ?? 1) as num).toDouble();
      final entry = ((p['entry'] ?? 1) as num).toDouble();
      notional[pair] = (notional[pair] ?? 0.0) + (qty * entry).abs();
      pairSide[pair] = (p['side'] ?? 'long').toString();
      pairChannel[pair] = (p['channel'] ?? '').toString();
      final pnl = ((p['unrealized_pnl'] ?? 0) as num).toDouble();
      pairPnl[pair] = (pairPnl[pair] ?? 0.0) + pnl;
      totalPnl += pnl;
    }

    final total = notional.values.fold(0.0, (a, b) => a + b);
    if (total == 0) return const SizedBox.shrink();

    final entries = notional.entries.toList();
    final pnlColor = totalPnl >= 0 ? kGreen : kRed;

    final t = _glowCtrl.value; // 0..1..0 (reverse: true = seamless loop)
    // Use sine for all oscillating values so 0→1→0 maps smoothly to full cycles
    final pulse = math.sin(t * math.pi); // 0→1→0, always smooth at endpoints
    final angle = t * 2 * math.pi;      // section gradient direction (reverses = back-forth, visually fine)

    final sections = List<PieChartSectionData>.generate(entries.length, (i) {
      final isTouched = i == _touchedIndex;
      final g = _gradients[i % _gradients.length];
      final a = angle + i * math.pi / 3;
      return PieChartSectionData(
        gradient: LinearGradient(
          colors: [g[0] as Color, g[1] as Color, g[0] as Color],
          stops: const [0.0, 0.5, 1.0],
          begin: Alignment(math.cos(a), math.sin(a)),
          end: Alignment(-math.cos(a), -math.sin(a)),
        ),
        value: entries[i].value,
        title: '',
        radius: isTouched ? 26 : 20,
        borderSide: BorderSide(
          color: isTouched ? Colors.white38 : Colors.transparent,
          width: isTouched ? 1.5 : 0,
        ),
      );
    });

    // Card border glow — uses pulse (0→1→0, seamless) for smooth loop
    final glow = _gradients[0][1] as Color;
    final glowOpacity = 0.12 + 0.12 * pulse; // 0.12..0.24, smooth at endpoints

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [
            Color.lerp(const Color(0xFF161410), const Color(0xFF201C0A), pulse)!,
            const Color(0xFF0C0C0C),
          ],
          // Direction oscillates between two stable endpoints — no wrap jump
          begin: Alignment(pulse * 2 - 1, (pulse * 2 - 1) * 0.5),
          end: Alignment(-(pulse * 2 - 1), -(pulse * 2 - 1) * 0.5),
        ),
        border: Border.all(color: glow.withOpacity(glowOpacity)),
        boxShadow: [
          BoxShadow(
            color: glow.withOpacity(glowOpacity * 0.6),
            blurRadius: 20,
            spreadRadius: 0,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                const Text('ПОЗИЦИИ',
                    style: TextStyle(color: kDim, fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.2)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: pnlColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: pnlColor.withOpacity(0.3), width: 0.5),
                  ),
                  child: Text(
                    _formatPnl(totalPnl),
                    style: TextStyle(color: pnlColor, fontSize: 11, fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Small ring — half size
                SizedBox(
                  width: 64,
                  height: 64,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      PieChart(
                        PieChartData(
                          sections: sections,
                          centerSpaceRadius: 18,
                          sectionsSpace: 2,
                          pieTouchData: PieTouchData(
                            touchCallback: (FlTouchEvent event, PieTouchResponse? resp) {
                              setState(() {
                                if (!event.isInterestedForInteractions ||
                                    resp == null || resp.touchedSection == null) {
                                  _touchedIndex = -1;
                                } else {
                                  _touchedIndex = resp.touchedSection!.touchedSectionIndex;
                                }
                              });
                            },
                          ),
                        ),
                      ),
                      Text(
                        '${entries.length}',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                // Legend
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: List.generate(entries.length, (i) {
                      final pair = entries[i].key;
                      final label = _cleanPair(pair);
                      final pct = entries[i].value / total * 100;
                      final side = pairSide[pair] ?? 'long';
                      final pnl = pairPnl[pair] ?? 0.0;
                      final channel = pairChannel[pair] ?? '';
                      final isLong = side == 'long';
                      final g = _gradients[i % _gradients.length];
                      final barColor = g[1] as Color;

                      return Padding(
                        padding: EdgeInsets.only(bottom: i < entries.length - 1 ? 8 : 0),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 3, height: 30,
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  colors: [g[0] as Color, g[1] as Color, g[0] as Color],
                                  stops: const [0.0, 0.5, 1.0],
                                  begin: Alignment(0, -1 + 2 * t),
                                  end: Alignment(0, 1 + 2 * t),
                                ),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(label,
                                          style: TextStyle(
                                              color: barColor,
                                              fontSize: 13,
                                              fontWeight: FontWeight.w700)),
                                      const SizedBox(width: 5),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                        decoration: BoxDecoration(
                                          color: (isLong ? kGreen : kRed).withOpacity(0.13),
                                          borderRadius: BorderRadius.circular(3),
                                        ),
                                        child: Text(
                                          isLong ? 'L' : 'S',
                                          style: TextStyle(
                                              color: isLong ? kGreen : kRed,
                                              fontSize: 9,
                                              fontWeight: FontWeight.w800),
                                        ),
                                      ),
                                    ],
                                  ),
                                  Row(
                                    children: [
                                      Text('${pct.toStringAsFixed(0)}%',
                                          style: const TextStyle(color: kDim, fontSize: 10)),
                                      if (channel.isNotEmpty) ...[
                                        const Text(' · ', style: TextStyle(color: kDim, fontSize: 10)),
                                        Flexible(
                                          child: Text(channel,
                                              style: const TextStyle(color: kDim, fontSize: 10),
                                              overflow: TextOverflow.ellipsis),
                                        ),
                                      ],
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              _formatPnl(pnl),
                              style: TextStyle(
                                color: pnl >= 0 ? kGreen : kRed,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawdownBar extends StatelessWidget {
  final double drawdownPct;
  const _DrawdownBar({required this.drawdownPct});

  @override
  Widget build(BuildContext context) {
    final pct = drawdownPct.clamp(0.0, 100.0);
    final Color barColor = pct >= 30
        ? kRed
        : pct >= 20
            ? const Color(0xFFFF9800) // orange
            : kGold;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: barColor.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Просадка', style: const TextStyle(color: kDim, fontSize: 11)),
              const Spacer(),
              Text(
                '${pct.toStringAsFixed(1)}%',
                style: TextStyle(
                    color: barColor, fontSize: 12, fontWeight: FontWeight.bold),
              ),
              if (pct >= 30)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Text('🛑', style: TextStyle(fontSize: 12)),
                )
              else if (pct >= 20)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Text('⚠️', style: TextStyle(fontSize: 12)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: pct / 100,
              minHeight: 4,
              backgroundColor: barColor.withOpacity(0.15),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _EquityCurveCard extends StatelessWidget {
  final List<double> points;
  const _EquityCurveCard({required this.points});

  @override
  Widget build(BuildContext context) {
    final last = points.last;
    final isUp = last >= 0;
    final color = isUp ? kGreen : kRed;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Equity curve',
                  style: TextStyle(color: kDim, fontSize: 11)),
              const Spacer(),
              Text(
                '${last >= 0 ? '+' : ''}\$${last.toStringAsFixed(2)}',
                style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 40,
            child: CustomPaint(
              size: const Size(double.infinity, 40),
              painter: _SparkPainter(
                prices: List.unmodifiable(points),
                isUp: isUp,
              ),
            ),
          ),
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

class _PositionCard extends StatefulWidget {
  final dynamic position;
  final VoidCallback onClose;
  final double? fundingRate;
  const _PositionCard(
      {required this.position, required this.onClose, this.fundingRate});

  @override
  State<_PositionCard> createState() => _PositionCardState();
}

class _PositionCardState extends State<_PositionCard> {
  double? _livePrice;
  final List<double> _priceHistory = [];
  StreamSubscription<WsSnapshot>? _wsSub;
  bool _historyLoaded = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    // Live price from global WebSocket — updates every 2s
    _wsSub = _globalWsService.stream.listen((snap) {
      if (!mounted) return;
      final Map<String, dynamic> p =
          widget.position is Map<String, dynamic> ? widget.position as Map<String, dynamic> : {};
      final posId = p['id']?.toString() ?? '';
      // Find this position in the snapshot
      for (final sp in snap.positions) {
        if (sp['id']?.toString() == posId) {
          final price = (sp['last_price'] as num?)?.toDouble();
          if (price != null) {
            setState(() {
              _livePrice = price;
              _priceHistory.add(price);
              if (_priceHistory.length > 300) _priceHistory.removeAt(0);
            });
          }
          break;
        }
      }
    });
  }

  @override
  void dispose() {
    _wsSub?.cancel();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    final Map<String, dynamic> p =
        widget.position is Map<String, dynamic> ? widget.position as Map<String, dynamic> : {};
    final posId = p['id']?.toString() ?? '';
    if (posId.isEmpty) return;
    final data = await apiGet('/positions/history');
    if (data == null || !mounted) return;
    final hist = data[posId];
    if (hist is List) {
      final prices = hist
          .map((e) => (e is Map) ? (e['price'] as num?)?.toDouble() : null)
          .whereType<double>()
          .toList();
      if (prices.isNotEmpty) {
        setState(() {
          _priceHistory.insertAll(0, prices);
          _livePrice = prices.last;
          _historyLoaded = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> p =
        widget.position is Map<String, dynamic> ? widget.position as Map<String, dynamic> : {};
    final pair = p['pair'] ?? p['symbol'] ?? '—';
    final side = (p['side'] ?? p['direction'] ?? '').toString().toUpperCase();
    final entry = p['entry'] ?? p['entry_price'];
    final liqPrice = (p['liq_price'] as num?)?.toDouble();
    final leverage = (p['leverage'] as num?)?.toDouble();
    final sl = (p['sl'] as num?)?.toDouble();
    final tpPlanRaw = p['tp_plan'];
    final filledTp = (p['filled_tp'] as num?)?.toInt() ?? 0;
    final openedAtStr = p['opened_at']?.toString();
    final channelRaw = (p['channel'] ?? '').toString();
    final staticPnl = (p['unrealized_pnl'] as num?)?.toDouble() ??
        (p['pnl'] as num?)?.toDouble() ?? 0;
    final isLong = side.contains('LONG') || side.contains('BUY');
    final qty = (p['qty'] as num?)?.toDouble() ?? 0;

    // TP progress
    final int tpTotal = tpPlanRaw is List ? tpPlanRaw.length : 0;

    // TTL countdown (72h max age)
    int? ttlRemainingH;
    if (openedAtStr != null && openedAtStr.isNotEmpty) {
      try {
        final openedDt = DateTime.parse(openedAtStr).toUtc();
        final ageH = DateTime.now().toUtc().difference(openedDt).inHours;
        ttlRemainingH = (72 - ageH).clamp(0, 72);
      } catch (_) {}
    }

    // Channel short tag
    String channelTag = '';
    if (channelRaw.isNotEmpty) {
      if (channelRaw.toLowerCase().contains('нестеров') || channelRaw.toLowerCase().contains('nesterov')) {
        channelTag = 'НСТ';
      } else if (channelRaw.toLowerCase().contains('юра') || channelRaw.toLowerCase().contains('yura')) {
        channelTag = 'ЮРА';
      } else {
        channelTag = channelRaw.length > 4 ? channelRaw.substring(0, 4).toUpperCase() : channelRaw.toUpperCase();
      }
    }

    // Distance to liquidation %
    double? liqDistPct;
    if (liqPrice != null) {
      final ref = _livePrice ?? double.tryParse(entry?.toString() ?? '');
      if (ref != null && ref > 0) {
        liqDistPct = ((liqPrice - ref) / ref * 100).abs();
      }
    }

    // Compute live P&L in USD and % directly from _livePrice (updated every 2s via WS)
    double? livePnlPct;
    double? livePnlUsd;
    if (_livePrice != null && entry != null) {
      final entryPrice = double.tryParse(entry.toString());
      if (entryPrice != null && entryPrice > 0) {
        livePnlPct = isLong
            ? (_livePrice! - entryPrice) / entryPrice * 100
            : (entryPrice - _livePrice!) / entryPrice * 100;
        if (qty > 0) {
          livePnlUsd = isLong
              ? (_livePrice! - entryPrice) * qty
              : (entryPrice - _livePrice!) * qty;
        }
      }
    }
    final pnl = livePnlUsd ?? staticPnl;

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
                      if (leverage != null) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: kGold.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            '${leverage.toStringAsFixed(leverage % 1 == 0 ? 0 : 1)}x',
                            style: const TextStyle(
                                color: kGold,
                                fontSize: 11,
                                fontWeight: FontWeight.bold),
                          ),
                        ),
                      ],
                      if (channelTag.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 2),
                          decoration: BoxDecoration(
                            color: kDim.withOpacity(0.12),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(channelTag,
                              style: const TextStyle(
                                  color: kDim,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w600,
                                  letterSpacing: 0.3)),
                        ),
                      ],
                    ],
                  ),
                  if (entry != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Text('Вход: ${_formatPrice(entry)}',
                            style: const TextStyle(color: kDim, fontSize: 12)),
                        if (sl != null) ...[
                          const SizedBox(width: 10),
                          Text('SL: ${_formatPrice(sl)}',
                              style: const TextStyle(
                                  color: Color(0xFFFF8A80), fontSize: 12)),
                        ],
                      ],
                    ),
                  ],
                  if (liqPrice != null) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text('Ликв: ${_formatPrice(liqPrice)}',
                            style: const TextStyle(
                                color: Color(0xFFFF6B6B), fontSize: 12)),
                        if (liqDistPct != null) ...[
                          const SizedBox(width: 4),
                          Text('(−${liqDistPct.toStringAsFixed(1)}%)',
                              style: const TextStyle(
                                  color: Color(0xFFFF6B6B), fontSize: 11)),
                        ],
                      ],
                    ),
                  ],
                  if (_livePrice != null) ...[
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          'Live: \$${_livePrice!.toStringAsFixed(_livePrice! >= 100 ? 2 : 4)}',
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                        if (livePnlPct != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            '${livePnlPct >= 0 ? '+' : ''}${livePnlPct.toStringAsFixed(2)}%',
                            style: TextStyle(
                              color: livePnlPct >= 0 ? kGreen : kRed,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                  if (widget.fundingRate != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      'FR: ${widget.fundingRate! >= 0 ? '+' : ''}${(widget.fundingRate! * 100).toStringAsFixed(4)}%',
                      style: TextStyle(
                          color: widget.fundingRate! >= 0 ? kGreen : kRed,
                          fontSize: 11),
                    ),
                  ],
                  if (tpTotal > 0) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        for (int i = 0; i < tpTotal; i++) ...[
                          if (i > 0) const SizedBox(width: 4),
                          Container(
                            width: 16,
                            height: 16,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: i < filledTp
                                  ? kGreen.withOpacity(0.85)
                                  : kDim.withOpacity(0.2),
                              border: Border.all(
                                  color: i < filledTp
                                      ? kGreen
                                      : kDim.withOpacity(0.4),
                                  width: 1),
                            ),
                            child: Center(
                              child: Text('${i + 1}',
                                  style: TextStyle(
                                      color: i < filledTp
                                          ? Colors.black
                                          : kDim,
                                      fontSize: 9,
                                      fontWeight: FontWeight.bold)),
                            ),
                          ),
                        ],
                        if (ttlRemainingH != null) ...[
                          const Spacer(),
                          Text('TTL ${ttlRemainingH}ч',
                              style: TextStyle(
                                  color: ttlRemainingH < 12
                                      ? const Color(0xFFFF9800)
                                      : kDim,
                                  fontSize: 11)),
                        ],
                      ],
                    ),
                  ] else if (ttlRemainingH != null) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text('TTL ${ttlRemainingH}ч',
                          style: TextStyle(
                              color: ttlRemainingH < 12
                                  ? const Color(0xFFFF9800)
                                  : kDim,
                              fontSize: 11)),
                    ),
                  ],
                  const SizedBox(height: 2),
                  Text(
                      'P&L: ${pnl >= 0 ? '+' : ''}\$${pnl.toStringAsFixed(2)}',
                      style: TextStyle(
                          color: pnl >= 0 ? kGreen : kRed,
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            if (_priceHistory.length >= 2) ...[
              const SizedBox(width: 8),
              CustomPaint(
                size: const Size(60, 30),
                painter: _SparkPainter(
                  prices: List.unmodifiable(_priceHistory),
                  isUp: _priceHistory.last >= _priceHistory.first,
                ),
              ),
              const SizedBox(width: 4),
            ],
            ValueListenableBuilder<UiMode>(
              valueListenable: _uiMode,
              builder: (_, mode, __) => mode == UiMode.advanced
                  ? IconButton(
                      icon: const Icon(Icons.close, color: kRed),
                      onPressed: widget.onClose,
                      tooltip: 'Закрыть позицию',
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Spark-chart painter ──────────────────────────────────────────────────────
class _SparkPainter extends CustomPainter {
  final List<double> prices;
  final bool isUp;
  const _SparkPainter({required this.prices, required this.isUp});

  @override
  void paint(Canvas canvas, Size size) {
    if (prices.length < 2) return;
    final minP = prices.reduce((a, b) => a < b ? a : b);
    final maxP = prices.reduce((a, b) => a > b ? a : b);
    final range = maxP - minP;
    final paint = Paint()
      ..color = isUp ? kGreen : kRed
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final path = Path();
    for (var i = 0; i < prices.length; i++) {
      final x = i / (prices.length - 1) * size.width;
      final y = range > 0
          ? size.height - ((prices[i] - minP) / range) * size.height
          : size.height / 2;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_SparkPainter old) =>
      old.prices != prices || old.isUp != isUp;
}

// ─── Balance Card ─────────────────────────────────────────────────────────────
// ─── P&L Summary Card ─────────────────────────────────────────────────────────
class _PnlSummaryCard extends StatefulWidget {
  const _PnlSummaryCard();

  @override
  State<_PnlSummaryCard> createState() => _PnlSummaryCardState();
}

class _PnlSummaryCardState extends State<_PnlSummaryCard> {
  double _dailyPnl = 0;
  double _winRate = 0;
  String? _bestPair;
  double _bestPnl = 0;
  bool _loaded = false;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _fetch();
    _refreshTimer = Timer.periodic(const Duration(minutes: 2), (_) => _fetch());
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetch() async {
    final data = await apiGet('/stats/daily');
    if (data != null && mounted) {
      setState(() {
        _dailyPnl = (data['daily_pnl'] as num?)?.toDouble() ?? 0;
        _winRate = (data['win_rate'] as num?)?.toDouble() ?? 0;
        _bestPair = data['best_pair'] as String?;
        _bestPnl = (data['best_pnl'] as num?)?.toDouble() ?? 0;
        _loaded = true;
      });
    }
  }

  Widget _chip(String label, String value, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.35)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(value,
                style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(label,
                style: const TextStyle(color: kDim, fontSize: 10)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!_loaded) return const SizedBox.shrink();
    final pnlColor = _dailyPnl >= 0 ? kGreen : kRed;
    final pnlStr =
        '${_dailyPnl >= 0 ? '+' : ''}\$${_dailyPnl.toStringAsFixed(2)}';
    final winStr = '${_winRate.toStringAsFixed(1)}%';
    final bestStr = _bestPair != null
        ? '$_bestPair ${_bestPnl >= 0 ? '+' : ''}\$${_bestPnl.toStringAsFixed(2)}'
        : '—';
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kDim.withOpacity(0.25)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _chip('P&L сегодня', pnlStr, pnlColor),
          _chip('Win rate', winStr, _winRate >= 50 ? kGreen : kRed),
          _chip('Лучший', bestStr, kGold),
        ],
      ),
    );
  }
}

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
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        content: const Row(
          children: [
            CircularProgressIndicator(color: kGold),
            SizedBox(width: 16),
            Expanded(child: Text('Добавление канала...', style: TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
    final ok = await apiPost('/channels', result, auth: true);
    if (mounted) {
      Navigator.of(context).pop();
      if (ok != null) {
        _showToast('Канал добавлен');
        _fetch();
      } else {
        _showToast('Ошибка добавления');
      }
    }
  }

  Future<void> _deleteChannel(String id) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        content: const Row(
          children: [
            CircularProgressIndicator(color: kGold),
            SizedBox(width: 16),
            Expanded(child: Text('Удаление канала...', style: TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
    final ok = await apiDelete('/channels/$id', auth: true);
    if (mounted) {
      Navigator.of(context).pop();
      if (ok) {
        _showToast('Канал удалён');
        _fetch();
      } else {
        _showToast('Ошибка удаления');
      }
    }
  }

  Future<void> _toggleChannel(String id, bool active) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        content: const Row(
          children: [
            CircularProgressIndicator(color: kGold),
            SizedBox(width: 16),
            Expanded(child: Text('Изменение статуса...', style: TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
    final ok = await apiPatch('/channels/$id', {'active': !active}, auth: true);
    if (mounted) {
      Navigator.of(context).pop();
      if (ok) {
        _fetch();
      } else {
        _showToast('Ошибка изменения статуса');
      }
    }
  }

  Future<void> _analyzeChannel(String id) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: kCard,
        content: const Row(
          children: [
            CircularProgressIndicator(color: kGold),
            SizedBox(width: 16),
            Expanded(child: Text('Анализ канала...', style: TextStyle(color: Colors.white))),
          ],
        ),
      ),
    );
    final resp = await apiPost('/channels/$id/analyze', {}, auth: true);
    if (mounted) {
      Navigator.of(context).pop();
      if (resp != null) {
        _showToast('Анализ завершён');
      } else {
        _showToast('Ошибка анализа');
      }
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
          const _PnlSummaryCard(),
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
                      itemBuilder: (ctx, i) => ChannelCard(
                        key: ValueKey(_channels[i]['id']),
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

class ChannelCard extends StatefulWidget {
  final dynamic channel;
  final bool isOwner;
  final VoidCallback onDelete;
  final VoidCallback onToggle;
  final VoidCallback onAnalyze;
  const ChannelCard({
    super.key,
    required this.channel,
    required this.isOwner,
    required this.onDelete,
    required this.onToggle,
    required this.onAnalyze,
  });

  @override
  State<ChannelCard> createState() => _ChannelCardState();
}

class _ChannelCardState extends State<ChannelCard> {
  bool _expanded = false;
  List<dynamic> _positions = [];
  Timer? _posTimer;
  StreamSubscription<WsSnapshot>? _wsSub;

  String get _channelId {
    final c = widget.channel is Map<String, dynamic> ? widget.channel as Map<String, dynamic> : {};
    return (c['id'] ?? '').toString();
  }

  @override
  void initState() {
    super.initState();
    _fetchPositions();
    _posTimer = Timer.periodic(const Duration(seconds: 30), (_) => _fetchPositions());
    // Live P&L from WS — update positions every 2s
    _wsSub = _globalWsService.stream.listen((snap) {
      if (!mounted) return;
      if (snap.positions.isEmpty && _positions.isEmpty) return;
      final id = _channelId;
      final filtered = snap.positions.where((p) {
        final ch = (p['channel'] ?? '').toString();
        return ch.isEmpty || ch == id;
      }).toList();
      setState(() => _positions = filtered);
    });
  }

  @override
  void dispose() {
    _posTimer?.cancel();
    _wsSub?.cancel();
    super.dispose();
  }

  Future<void> _fetchPositions() async {
    final data = await apiGetList('/positions');
    if (!mounted) return;
    final Map<String, dynamic> c =
        widget.channel is Map<String, dynamic> ? widget.channel as Map<String, dynamic> : {};
    final channelId = (c['id'] ?? '').toString();
    final filtered = (data ?? []).where((p) {
      final pos = p is Map<String, dynamic> ? p : <String, dynamic>{};
      final ch = (pos['channel'] ?? '').toString();
      return ch.isEmpty || ch == channelId;
    }).toList();
    setState(() => _positions = filtered);
  }

  Future<void> _closePosition(dynamic pos) async {
    final p = pos is Map<String, dynamic> ? pos : <String, dynamic>{};
    final id = p['id']?.toString() ?? p['order_id']?.toString();
    if (id == null) return;
    await apiDelete('/positions/$id', auth: true);
    if (!mounted) return;
    _fetchPositions();
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> c =
        widget.channel is Map<String, dynamic> ? widget.channel as Map<String, dynamic> : {};
    final name = c['name'] ?? c['title'] ?? '—';
    final active = c['active'] == true;
    final pnl = (c['daily_pnl'] as num?)?.toDouble();
    final hasPositions = _positions.isNotEmpty;
    final totalPnl = _positions.fold<double>(0.0, (sum, p) {
      final pos = p is Map<String, dynamic> ? p : <String, dynamic>{};
      return sum + ((pos['unrealized_pnl'] as num?)?.toDouble() ??
          (pos['pnl'] as num?)?.toDouble() ?? 0.0);
    });

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row — tap opens stats sheet ────────────────────────────
          InkWell(
            onTap: () => _showChannelStats(context, c['id'].toString(), name.toString()),
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, 12, 12, hasPositions ? 4 : 12),
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
                      if (widget.isOwner)
                        ValueListenableBuilder<UiMode>(
                          valueListenable: _uiMode,
                          builder: (_, mode, __) => mode == UiMode.advanced
                              ? Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: Icon(
                                          active
                                              ? Icons.pause_circle
                                              : Icons.play_circle,
                                          color: kGold,
                                          size: 20),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: widget.onToggle,
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(Icons.analytics_outlined,
                                          color: kDim, size: 20),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: widget.onAnalyze,
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(Icons.delete_outline,
                                          color: kRed, size: 20),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: widget.onDelete,
                                    ),
                                  ],
                                )
                              : const SizedBox.shrink(),
                        ),
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
                  if (!hasPositions) ...[
                    const SizedBox(height: 4),
                    const Text('Нажмите для статистики канала',
                        style: TextStyle(color: kDim, fontSize: 11)),
                  ],
                ],
              ),
            ),
          ),
          // ── Accordion row — visible only when there are active positions ──
          if (hasPositions) ...[
            const Divider(height: 1, color: Color(0xFF252525)),
            InkWell(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      color: kGold,
                      size: 18,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      'Активные сделки: ${_positions.length}',
                      style: const TextStyle(color: kDim, fontSize: 12),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: (totalPnl >= 0 ? kGreen : kRed).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: (totalPnl >= 0 ? kGreen : kRed).withOpacity(0.4),
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        '${totalPnl >= 0 ? '+' : ''}\$${totalPnl.toStringAsFixed(2)}',
                        style: TextStyle(
                          color: totalPnl >= 0 ? kGreen : kRed,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                child: Column(
                  children: _positions
                      .map((pos) => _PositionCard(
                            position: pos,
                            onClose: () => _closePosition(pos),
                          ))
                      .toList(),
                ),
              ),
          ],
        ],
      ),
    );
  }
}

void _showChannelStats(BuildContext context, String channelId, String channelName) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ChannelStatsSheet(channelId: channelId, channelName: channelName),
  );
}

class _ChannelStatsSheet extends StatefulWidget {
  final String channelId;
  final String channelName;
  const _ChannelStatsSheet({required this.channelId, required this.channelName});

  @override
  State<_ChannelStatsSheet> createState() => _ChannelStatsSheetState();
}

class _ChannelStatsSheetState extends State<_ChannelStatsSheet> {
  Map<String, dynamic>? _stats;
  List<dynamic> _positions = [];
  bool _loading = true;
  Timer? _posTimer;

  @override
  void initState() {
    super.initState();
    _fetch();
    _posTimer = Timer.periodic(const Duration(seconds: 15), (_) => _fetchPositions());
  }

  @override
  void dispose() {
    _posTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchPositions() async {
    final data = await apiGetList('/positions', auth: true);
    if (mounted && data != null) setState(() => _positions = data);
  }

  Future<void> _fetch() async {
    final results = await Future.wait([
      apiGet('/stats/channel?name=${Uri.encodeComponent(widget.channelName)}'),
      apiGetList('/positions', auth: true),
    ]);
    if (mounted) {
      setState(() {
        _stats = (results[0] as Map<String, dynamic>?) ?? {
          'total_signals': 0, 'wins': 0, 'losses': 0,
          'win_rate': 0.0, 'avg_pnl': 0.0, 'total_pnl': 0.0,
          'closed_trades': 0, 'best_pair': null, 'worst_pair': null,
        };
        _positions = (results[1] as List<dynamic>?) ?? [];
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _stats;
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      builder: (_, sc) => Container(
        decoration: const BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: ListView(
          controller: sc,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(widget.channelName,
                      style: const TextStyle(
                          color: kGold,
                          fontSize: 17,
                          fontWeight: FontWeight.bold)),
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: kDim),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const Divider(color: kDim, height: 1),
            const SizedBox(height: 16),
            if (_loading)
              const Center(child: CircularProgressIndicator(color: kGold))
            else ...[
              // ── История сигналов ──────────────────────────────────────
              OutlinedButton.icon(
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChannelSignalsScreen(
                          channelId: widget.channelId,
                          channelName: widget.channelName),
                    ),
                  );
                },
                icon: const Icon(Icons.list_alt, color: kGold),
                label: const Text('История сигналов',
                    style: TextStyle(color: kGold)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: kGold),
                  minimumSize: const Size.fromHeight(44),
                ),
              ),
              // ── Активные сделки ───────────────────────────────────────
              if (_positions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Row(children: [
                  const Icon(Icons.show_chart, color: kGold, size: 16),
                  const SizedBox(width: 6),
                  const Text('Активные сделки',
                      style: TextStyle(
                          color: kGold,
                          fontSize: 13,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: kGreen.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text('${_positions.length}',
                        style: const TextStyle(color: kGreen, fontSize: 11)),
                  ),
                ]),
                const SizedBox(height: 8),
                ..._positions.map((p) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _PositionCard(
                    position: p,
                    onClose: () async {
                      final id = p['id']?.toString();
                      if (id != null) {
                        await apiDelete('/positions/$id', auth: true);
                        if (!mounted) return;
                        _fetchPositions();
                      }
                    },
                  ),
                )),
              ],
              // ── Сводная статистика ─────────────────────────────────────
              if (s != null) ...[
                const SizedBox(height: 20),
                const Text('Статистика',
                    style: TextStyle(
                        color: kDim, fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    _StatChip('Сигналов',
                        '${s['total_signals'] ?? 0}', kGold),
                    _StatChip('Побед',
                        '${s['wins'] ?? 0} / ${s['losses'] ?? 0}', kGreen),
                    _StatChip('Win Rate',
                        '${s['win_rate'] ?? 0}%',
                        (s['win_rate'] as num? ?? 0) >= 50 ? kGreen : kRed),
                    _StatChip('Avg P&L',
                        '${(s['avg_pnl'] as num? ?? 0) >= 0 ? '+' : ''}\$${(s['avg_pnl'] as num? ?? 0).toStringAsFixed(2)}',
                        (s['avg_pnl'] as num? ?? 0) >= 0 ? kGreen : kRed),
                    _StatChip('Total P&L',
                        '${(s['total_pnl'] as num? ?? 0) >= 0 ? '+' : ''}\$${(s['total_pnl'] as num? ?? 0).toStringAsFixed(2)}',
                        (s['total_pnl'] as num? ?? 0) >= 0 ? kGreen : kRed),
                    if (s['best_pair'] != null)
                      _StatChip('Лучшая пара',
                          '${s['best_pair']} +\$${(s['best_pair_pnl'] as num? ?? 0).toStringAsFixed(2)}',
                          kGreen),
                    if (s['worst_pair'] != null)
                      _StatChip('Худшая пара',
                          '${s['worst_pair']} \$${(s['worst_pair_pnl'] as num? ?? 0).toStringAsFixed(2)}',
                          kRed),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  const _StatChip(this.label, this.value, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value,
              style: TextStyle(
                  color: color,
                  fontSize: 13,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(color: kDim, fontSize: 10)),
        ],
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
                  itemBuilder: (ctx, i) => SignalCard(signal: _signals[i], showPnlAlways: true),
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
