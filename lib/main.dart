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

  // --- تصحيح الخطأ هنا ---
  // تم تغيير التسمية لتطابق المتغير المستخدم في InitializationSettings
  const AndroidInitializationSettings initializationSettingsAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  
  // إزالة const إذا واجهت مشكلة في التجميع، لكن التسمية هي السبب الأساسي
  const InitializationSettings initializationSettings = InitializationSettings(android: initializationSettingsAndroid);
  
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  SharedPreferences prefs = await SharedPreferences.getInstance();
  String? savedID = prefs.getString('car_id');
  String? userType = prefs.getString('user_type');
  bool isDark = prefs.getBool('dark_mode') ?? false;
  
  themeNotifier.value = isDark ? ThemeMode.dark : ThemeMode.light;

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

// --- كلاس التطبيق الرئيسي مع إضافة منطق البصمة ---
class HasbaApp extends StatefulWidget {
  final String? savedID;
  final String? userType;
  const HasbaApp({super.key, this.savedID, this.userType});

  @override
  State<HasbaApp> createState() => _HasbaAppState();
}

class _HasbaAppState extends State<HasbaApp> {
  bool _isAuthenticated = false; // هل تم التحقق من الهوية؟
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
    _checkBiometricPreference();
  }

  // فحص هل المستخدم فعل خيار البصمة من الإعدادات؟
  Future<void> _checkBiometricPreference() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    bool isBiometricEnabled = prefs.getBool('biometric_enabled') ?? false;

    if (isBiometricEnabled) {
      _authenticateUser();
    } else {
      setState(() {
        _isAuthenticated = true; // الدخول مباشرة إذا كانت الخدمة معطلة
      });
    }
  }

  // تنفيذ عملية التحقق من البصمة
  Future<void> _authenticateUser() async {
    try {
      bool authenticated = await _auth.authenticate(
        localizedReason: 'يرجى تأكيد هويتك لفتح نظام HASBA TRACKER',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
      setState(() {
        _isAuthenticated = authenticated;
      });
    } catch (e) {
      print("خطأ في التحقق الحيوي: $e");
      // في حال حدوث خطأ تقني، يمكن السماح بالدخول أو طلب PIN
      setState(() {
        _isAuthenticated = true; 
      });
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
          // التعديل هنا: إذا لم يتم التحقق تظهر شاشة سوداء/انتظار حتى نجاح البصمة
          home: _isAuthenticated 
              ? SplashScreen(savedID: widget.savedID, userType: widget.userType)
              : _biometricLockScreen(),
        );
      },
    );
  }

  // شاشة حماية تظهر أثناء انتظار البصمة
  Widget _biometricLockScreen() {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.lock_outline, size: 80, color: Colors.blue),
            const SizedBox(height: 20),
            const Text("التطبيق مغلق للأمان", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: _authenticateUser,
              child: const Text("اضغط للمحاولة مرة أخرى"),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> requestPermissions() async {
  await Permission.notification.request();
  Map<Permission, PermissionStatus> statuses = await [
    Permission.location,
    Permission.phone,
    Permission.sensors,
    Permission.ignoreBatteryOptimizations, 
    Permission.systemAlertWindow, 
  ].request();
  print("Permissions status: $statuses");
}