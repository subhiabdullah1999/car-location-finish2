import 'package:car_location/ui/admin_page.dart';
import 'package:car_location/ui/car_device_page.dart';
import 'package:car_location/ui/splash_page.dart';
import 'package:car_location/ui/type_selctor_page.dart'; 
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'services/car_security_service.dart';
// مكتبات الإشعارات والخدمة الأمامية
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:local_auth/local_auth.dart'; // مكتبة البصمة المضافة

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

// تهيئة محرك الإشعارات
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  await Firebase.initializeApp();
  FirebaseDatabase.instance.databaseURL = "https://car-location-67e15-default-rtdb.firebaseio.com/";

  // إعداد قنوات الإشعارات للأندرويد
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  SharedPreferences prefs = await SharedPreferences.getInstance();
  String? savedID = prefs.getString('car_id');
  String? userType = prefs.getString('user_type');
  bool isDark = prefs.getBool('dark_mode') ?? false;
  
  themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;

  // استدعاء السماحيات بشكل آمن مرة واحدة عند التشغيل
  await requestPermissions();

  // إذا كان المستخدم "أدمن"، نبدأ مراقبة الرادار فوراً
  if (userType == 'admin' && savedID != null) {
    startForegroundMonitoring(savedID);
  }

  runApp(HasbaApp(savedID: savedID, userType: userType));
}

// دالة الرادار الدائم (الخدمة الأمامية البرمجية)
void startForegroundMonitoring(String carID) {
  DatabaseReference ref = FirebaseDatabase.instance.ref('devices/$carID/responses');
  
  ref.onValue.listen((event) async {
    if (event.snapshot.value != null) {
      Map data = event.snapshot.value as Map;
      String type = data['type'] ?? '';
      String msg = data['message'] ?? '';
      String currentId = data['id']?.toString() ?? "";

      SharedPreferences prefs = await SharedPreferences.getInstance();
      String? lastId = prefs.getString('last_handled_id');

      if (currentId != lastId && currentId.isNotEmpty) {
        await prefs.setString('last_handled_id', currentId);
        _triggerUrgentNotification(type, msg);

        if (type == 'alert') {
          print("🚨 اهتزاز قوي detected! جاري التنبيه الفوري...");
        }
      }
    }
  });
}

Future<void> _triggerUrgentNotification(String type, String msg) async {
  AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
    'car_radar_channel', 
    'رادار الحماية',
    importance: Importance.max,
    priority: Priority.high,
    fullScreenIntent: true, 
    ongoing: type == 'alert', 
    styleInformation: BigTextStyleInformation(msg),
    playSound: true,
    enableVibration: true,
    channelShowBadge: true,
  );

  NotificationDetails platformChannelSpecifics = NotificationDetails(android: androidPlatformChannelSpecifics);
  
  await flutterLocalNotificationsPlugin.show(
    0, 
    type == 'alert' ? "🚨 تنبيه أمني خطير!" : "ℹ️ تحديث من السيارة",
    msg, 
    platformChannelSpecifics
  );
}

// --- كلاس التطبيق الرئيسي مع إضافة مراقب الحالة (Observer) ---
class HasbaApp extends StatefulWidget {
  final String? savedID;
  final String? userType;
  const HasbaApp({super.key, this.savedID, this.userType});

  @override
  State<HasbaApp> createState() => _HasbaAppState();
}

class _HasbaAppState extends State<HasbaApp> with WidgetsBindingObserver {
  bool _isAuthenticated = false; 
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkBiometricPreference();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkBiometricPreference();
    } else if (state == AppLifecycleState.paused) {
      setState(() {
        _isAuthenticated = false;
      });
    }
  }

  Future<void> _checkBiometricPreference() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    bool isBiometricEnabled = prefs.getBool('biometric_enabled') ?? false;

    if (isBiometricEnabled) {
      _authenticateUser();
    } else {
      if(mounted) {
        setState(() {
          _isAuthenticated = true; 
        });
      }
    }
  }

  Future<void> _authenticateUser() async {
    try {
      bool authenticated = await _auth.authenticate(
        localizedReason: 'يرجى تأكيد هويتك لفتح نظام HASBA TRACKER',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
      if(mounted) {
        setState(() {
          _isAuthenticated = authenticated;
        });
      }
    } catch (e) {
      print("خطأ في التحقق الحيوي: $e");
      if(mounted) {
        setState(() {
          _isAuthenticated = true; 
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (_, ThemeMode currentMode, __) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Hasba Tracker',
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            colorSchemeSeed: Colors.blue.shade900,
            appBarTheme: AppBarTheme(backgroundColor: Colors.blue.shade900, foregroundColor: Colors.white),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            scaffoldBackgroundColor: const Color(0xFF121212),
            colorSchemeSeed: Colors.blue,
            cardTheme: const CardTheme(color: Color(0xFF1E1E1E)),
            appBarTheme: const AppBarTheme(backgroundColor: Color(0xFF1F1F1F), foregroundColor: Colors.white),
          ),
          themeMode: currentMode,
          home: _isAuthenticated 
              ? SplashScreen(savedID: widget.savedID, userType: widget.userType)
              : _biometricLockScreen(),
        );
      },
    );
  }

  Widget _biometricLockScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFF121212), 
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_person, size: 100, color: Colors.blue),
            const SizedBox(height: 20),
            const Text(
              "نظام HASBA مغلق للأمان",
              style: TextStyle(fontSize: 20, color: Colors.white, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 10),
            const Text(
              "يرجى استخدام البصمة للدخول",
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: _authenticateUser,
              icon: const Icon(Icons.fingerprint),
              label: const Text("فتح القفل الآن"),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(200, 50),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// الحل الجذري لمشكلة تعليق البطارية والسماحيات
Future<void> requestPermissions() async {
  // أولاً: طلب سماحية الإشعارات لأنها أساسية
  await Permission.notification.request();

  // ثانياً: فحص حالة سماحية البطارية قبل طلبها لتجنب التكرار والتعليق
  if (!await Permission.ignoreBatteryOptimizations.isGranted) {
    await Permission.ignoreBatteryOptimizations.request();
  }

  // ثالثاً: طلب باقي السماحيات في دفعة واحدة
  Map<Permission, PermissionStatus> statuses = await [
    Permission.location,
    Permission.phone,
    Permission.sensors,
    Permission.systemAlertWindow, 
  ].request();
  
  print("Permissions status: $statuses");
}