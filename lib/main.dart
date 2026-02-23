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

  // إذا كان المستخدم "أدمن"، نبدأ مراقبة الرادار فوراً
  if (userType == 'admin' && savedID != null) {
    startForegroundMonitoring(savedID);
  }

  runApp(HasbaApp(savedID: savedID, userType: userType));
}

// دالة الرادار الدائم (الخدمة الأمامية البرمجية)
void startForegroundMonitoring(String carID) {
  DatabaseReference ref = FirebaseDatabase.instance.ref('devices/$carID/responses');
  
  // الاستماع اللحظي (Stream) - يعمل في الخلفية طالما التطبيق مفتوح أو في الـ RAM
  ref.onValue.listen((event) async {
    if (event.snapshot.value != null) {
      Map data = event.snapshot.value as Map;
      String type = data['type'] ?? '';
      String msg = data['message'] ?? '';
      String currentId = data['id']?.toString() ?? "";

      SharedPreferences prefs = await SharedPreferences.getInstance();
      String? lastId = prefs.getString('last_handled_id');

      // تفعيل التنبيه فوراً إذا كان ID الإشعار جديداً
      if (currentId != lastId && currentId.isNotEmpty) {
        await prefs.setString('last_handled_id', currentId);
        
        // 1. إظهار إشعار عالي الأولوية
        _triggerUrgentNotification(type, msg);

        // 2. إذا كان "تنبيه أمني" (اهتزاز قوي)، يمكن تفعيل اتصال أو صوت إنذار
        if (type == 'alert') {
          // هنا يمكنك إضافة كود الاتصال التلقائي إذا أردت
          print("🚨 اهتزاز قوي detected! جاري التنبيه الفوري...");
        }
      }
    }
  });
}

// إظهار إشعار لا يمكن تجاهله (Urgent)
Future<void> _triggerUrgentNotification(String type, String msg) async {
  // إعدادات الصوت: إذا كان تنبيه أمني نستخدم صوت مرتفع
  // ملاحظة: لكي يعمل الصوت المخصص 'alarm' يجب وضعه في مجلد res/raw في أندرويد
  // حالياً سنستخدم الصوت الافتراضي للتنبيهات لضمان عمل الكود
  
  AndroidNotificationDetails androidPlatformChannelSpecifics = AndroidNotificationDetails(
    'car_radar_channel', 
    'رادار الحماية',
    importance: Importance.max,
    priority: Priority.high,
    fullScreenIntent: true, 
    ongoing: type == 'alert', 
    styleInformation: BigTextStyleInformation(msg),
    // استبدال playSiren بالصوت الافتراضي أو المخصص
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

class HasbaApp extends StatelessWidget {
  final String? savedID;
  final String? userType;
  const HasbaApp({super.key, this.savedID, this.userType});

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
          home: SplashScreen(savedID: savedID, userType: userType),
        );
      },
    );
  }
}

Future<void> requestPermissions() async {
  await Permission.notification.request();
  Map<Permission, PermissionStatus> statuses = await [
    Permission.location,
    Permission.phone,
    Permission.sensors,
    Permission.ignoreBatteryOptimizations, // ضروري جداً لضمان عمل الرادار
    Permission.systemAlertWindow, // ضروري لفتح نوافذ فوق التطبيقات الأخرى
  ].request();
  print("Permissions status: $statuses");
}