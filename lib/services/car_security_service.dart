import 'dart:math' as math;
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'dart:async';
import 'dart:io';

class CarSecurityService {
  static final CarSecurityService _instance = CarSecurityService._internal();
  factory CarSecurityService() => _instance;
  static const platform = MethodChannel('hasba.security/hotspot');
  
  // --- متغيرات تتبع الرحلة والسرعة القصوى ---
  double _maxSpeed = 0.0; 
  double _totalDistance = 0.0;
  Position? _lastPosition;
  StreamSubscription<Position>? _positionStream;
  bool _isTestMode = false; // فعله لتجربة العداد بدون حركة
  
  // --- ميزة تنبيه تجاوز السرعة الجديدة ---
  double _speedLimit = 90.0; // الحد الافتراضي
  bool _speedAlertSent = false; // لمنع تكرار الإشعارات
  StreamSubscription? _limitSub;
  // ----------------------------------------

  // متغير مضاف للتحكم في مؤقت وضع الاختبار بدقة
  Timer? _testTimer;

  CarSecurityService._internal();

  final DatabaseReference _dbRef = FirebaseDatabase.instance.ref();
  
  StreamSubscription? _vibeSub, _locSub, _cmdSub, _trackSub, _sensSub, _numsSub, _vibeToggleSub, _geoSub;
  
  // متغيرات مراقبة الشحن الجديدة
  StreamSubscription<BatteryState>? _batteryStateSub;
  // أضفت هذه المتغيرات لمنع تكرار الإشعارات
  bool _isChargingSent = false;
  bool _isDischargingSent = false;

  bool isSystemActive = false;
  bool _vibrationEnabled = true; 
  bool _isCallingNow = false; 
  bool _lowBatteryAlertSent = false; 
  String? myCarID;
  double? sLat, sLng;
  double _threshold = 20.0;
  double _geofenceRadius = 200.0; 
  
  List<String> _emergencyNumbers = [];

  void initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'car_security_channel',
        channelName: 'Hasba Security Service',
        channelDescription: 'نظام حماية السيارة يعمل في الخلفية',
        channelImportance: NotificationChannelImportance.MAX,
        priority: NotificationPriority.MAX,
        iconData: const NotificationIconData(
          resType: ResourceType.mipmap,
          resPrefix: ResourcePrefix.ic,
          name: 'launcher',
        ),
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: true, playSound: true),
      foregroundTaskOptions: const ForegroundTaskOptions(
        interval: 5000,
        isOnceEvent: false,
        autoRunOnBoot: true,
        allowWakeLock: true,
      ),
    );
  }

  Future<void> initSecuritySystem() async {
    if (isSystemActive) return;

    try {
      initForegroundTask();
      await FlutterForegroundTask.startService(
        notificationTitle: '🛡️ نظام حماية HASBA نشط',
        notificationText: 'جاري مراقبة السيارة وحمايتها الآن...',
      );

      SharedPreferences prefs = await SharedPreferences.getInstance();
      myCarID = prefs.getString('car_id');

      Position? p = await Geolocator.getLastKnownPosition();
      p ??= await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);

      sLat = p.latitude; 
      sLng = p.longitude;

      isSystemActive = true;
      
      if (myCarID != null) {
        await _dbRef.child('devices/$myCarID/system_active_status').set(true);
        await _dbRef.child('devices/$myCarID/vibration_enabled').set(true);
        await prefs.setBool('was_system_active', true);
        _listenToSpeedLimit(); // تفعيل الاستماع لحد السرعة عند بدء النظام
      }

      _startSensors();          
      _listenToNumbers();       
      _listenToVibrationToggle(); 
      _listenToGeofenceRadius(); 
      _startBatteryMonitor();    
      _startBatteryStateMonitor(); // تفعيل مراقبة توصيل وفصل الشاحن

      _send('status', '🛡️ تم تفعيل نظام الحماية بنجاح والموقع المرجعي مؤمن');
      print("✅ [Security System] تم التفعيل بنجاح للمعرف: $myCarID");

    } catch (e) {
      print("❌ [Security System] فشل في التفعيل: $e");
      isSystemActive = false; 
      if (myCarID != null) {
        await _dbRef.child('devices/$myCarID/system_active_status').set(false);
      }
      _send('status', '⚠️ فشل في تفعيل النظام تلقائياً');
    }
  }

  // ميزة مراقبة حالة الشاحن (توصيل/فصل) المعدلة لمنع التكرار
  void _startBatteryStateMonitor() {
    _batteryStateSub?.cancel();
    _batteryStateSub = Battery().onBatteryStateChanged.listen((BatteryState state) {
      if (!isSystemActive) return;
      
      if (state == BatteryState.charging) {
        if (!_isChargingSent) {
          _send('status', '🔌 تنبيه: تم توصيل الشاحن بجهاز السيارة الآن');
          _isChargingSent = true;
          _isDischargingSent = false; // إعادة السماح بإرسال تنبيه الفصل
        }
      } else if (state == BatteryState.discharging) {
        if (!_isDischargingSent) {
          _send('alert', '🔌 تحذير: تم فصل الشاحن عن جهاز السيارة!');
          _isDischargingSent = true;
          _isChargingSent = false; // إعادة السماح بإرسال تنبيه التوصيل
        }
      }
    });
  }

  // ميزة الاستماع لحد السرعة المحدد من الأدمن
  void _listenToSpeedLimit() {
    if (myCarID == null) return;
    _limitSub = _dbRef.child('devices/$myCarID/speed_limit').onValue.listen((event) {
      if (event.snapshot.value != null) {
        _speedLimit = double.tryParse(event.snapshot.value.toString()) ?? 90.0;
      }
    });
  }

  void _startBatteryMonitor() {
    Timer.periodic(const Duration(minutes: 15), (timer) async {
      if (!isSystemActive) { timer.cancel(); return; }
      int level = await Battery().batteryLevel;
      if (level < 20 && !_lowBatteryAlertSent) {
        _send('alert', '🪫 تنبيه: بطارية هاتف السيارة منخفضة جداً ($level%)');
        _lowBatteryAlertSent = true;
      } else if (level > 30) {
        _lowBatteryAlertSent = false; 
      }
    });
  }

  void _listenToGeofenceRadius() {
    if (myCarID == null) return;
    _geoSub = _dbRef.child('devices/$myCarID/geofence_radius').onValue.listen((event) {
      if (event.snapshot.value != null) {
        _geofenceRadius = double.parse(event.snapshot.value.toString());
      }
    });
  }

  void _listenToVibrationToggle() {
    if (myCarID == null) return;
    _vibeToggleSub = _dbRef.child('devices/$myCarID/vibration_enabled').onValue.listen((event) {
      if (event.snapshot.value != null) {
        _vibrationEnabled = event.snapshot.value as bool;
      }
    });
  }

  void _listenToNumbers() {
    if (myCarID == null) return;
    _numsSub = _dbRef.child('devices/$myCarID/numbers').onValue.listen((event) {
      if (event.snapshot.value != null) {
        try {
          List<String> tempNumbers = [];
          var data = event.snapshot.value;

          if (data is Map) {
            tempNumbers.add(data['1']?.toString() ?? "");
            tempNumbers.add(data['2']?.toString() ?? "");
            tempNumbers.add(data['3']?.toString() ?? "");
          } else if (data is List) {
            for (var item in data) {
              if (item != null) tempNumbers.add(item.toString());
            }
          }
          _emergencyNumbers = tempNumbers.where((e) => e.isNotEmpty).toList();
        } catch (e) {
          print("❌ خطأ في تنسيق الأرقام: $e");
        }
      }
    });
  }

  void _listenToSensitivity() {
    _sensSub = _dbRef.child('devices/$myCarID/sensitivity').onValue.listen((event) {
      if (event.snapshot.value != null) {
        _threshold = double.parse(event.snapshot.value.toString());
      }
    });
  }

  void _startSensors() {
    _listenToSensitivity();
    _vibeSub = accelerometerEvents.listen((e) {
      if (isSystemActive && _vibrationEnabled && !_isCallingNow) {
        if (e.x.abs() > _threshold || e.y.abs() > _threshold || e.z.abs() > _threshold) {
          _send('alert', '⚠️ تحذير: اهتزاز قوي مكتشف!');
          _startDirectCalling(); 
        }
      }
    });

    _locSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, distanceFilter: 10)
    ).listen((pos) {
      if (sLat != null && sLat != 0 && isSystemActive) {
        double dist = Geolocator.distanceBetween(sLat!, sLng!, pos.latitude, pos.longitude);
        if (dist > _geofenceRadius) {
          _startEmergencyProtocol(dist, pos.latitude, pos.longitude);
          _locSub?.cancel(); 
        }
      }
    });
  }

  void startListeningForCommands(String carID) {
    myCarID = carID;
    _cmdSub?.cancel(); 
    
    _cmdSub = _dbRef.child('devices/$myCarID/commands').onValue.listen((e) async {
      if (e.snapshot.value != null) {
        var data = e.snapshot.value as Map;
        int id = data['id'] ?? 0;
        
        print("📥 أمر مستلم: $id | الحالة: $isSystemActive");

        switch (id) {
          case 7:
            if (!isSystemActive) {
              await initSecuritySystem();
            } else {
              _send('status', '🛡️ النظام نشط بالفعل');
            }
            break;

          case 6:
            if (isSystemActive) {
              await stopSecuritySystem();
            } else {
              _send('status', '🔓 النظام متوقف بالفعل');
            }
            break;

          case 1:
            if (isSystemActive) {
              await sendLocation();
            } else {
              _send('status', '❌ النظام متوقف، تعذر جلب الموقع');
            }
            break;

          case 2:
            await sendBattery();
            break;

          case 3: 
          case 5:
            if (isSystemActive) {
              _startDirectCalling();
            } else {
              _send('status', '❌ النظام متوقف، تعذر الاتصال');
            }
            break;

          case 8:
            _send('status', '🔄 جاري تصفير الحساسات وإعادة التشغيل...');
            await stopSecuritySystem();
            await Future.delayed(const Duration(seconds: 3));
            await initSecuritySystem();
            _send('status', '✅ تمت إعادة التشغيل بنجاح؛ النظام الآن نشط');
            break;

        case 9:
            _send('status', '🌐 جاري فتح إعدادات الشبكة في السيارة...');
            try {
              final String result = await platform.invokeMethod('enableHotspot');
              
              if (result == "SUCCESS") {
                final String details = await platform.invokeMethod('getHotspotDetails');
                _send('status', '✅ تم التفعيل بنجاح\n$details');
              } else if (result == "OPENED_SETTINGS") {
                _send('status', '⚙️ تم فتح صفحة الـ Hotspot في هاتف السيارة بنجاح. يرجى تفعيل المفتاح يدوياً.');
              } else if (result == "NEED_PERMISSION_UI") {
                _send('status', '⚠️ يرجى منح صلاحية تعديل الإعدادات في هاتف السيارة أولاً');
              } else {
                _send('status', '❌ تعذر التحكم: $result');
              }
            } catch (e) {
              _send('status', '❌ خطأ في النظام: $e');
            }
            break;

            case 10:
            await platform.invokeMethod('disableHotspot'); 
            _send('status', '📴 تم إيقاف نقطة الاتصال لتوفير البطارية');
            break;
        }
      }
    });

    _dbRef.child('devices/$carID/test_mode').onValue.listen((event) {
      bool isTest = event.snapshot.value == true;
      _testTimer?.cancel(); 

      if (isTest) {
        _send('status', '🧪 تم تفعيل وضع الاختبار؛ سيتم إرسال سرعات وهمية الآن');
        _testTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
          if (event.snapshot.value != true) { 
            timer.cancel(); 
            return; 
          }
          
          double mockSpeed = 60.0 + math.Random().nextDouble() * 60.0;
          
          if (mockSpeed > _maxSpeed) {
            _maxSpeed = mockSpeed;
          }

          _dbRef.child('devices/$carID/trip_data').update({
            'current_speed': mockSpeed.toInt(),
            'max_speed': _maxSpeed.toInt(), 
            'last_update': ServerValue.timestamp,
          });
        });
      } else {
        _send('status', '🔌 تم إيقاف وضع الاختبار والعودة للبيانات الحقيقية');
      }
    });

    _startTripTracking(carID);
    _listenForResetCommand(carID);
  }

  void _startTripTracking(String carId) async {
    LocationSettings locationSettings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 2,
      foregroundNotificationConfig: ForegroundNotificationConfig(
        notificationTitle: "جاري تتبع الرحلة",
        notificationText: "نظام HASBA يراقب السرعة الآن",
      )
    );

    _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((Position position) {
      
      double speedKmh = position.speed > 0 ? position.speed * 3.6 : 0.0;
      
      if (speedKmh < 0.8) speedKmh = 0; 

      if (_isTestMode && speedKmh == 0) speedKmh = 105.0; 

      if (speedKmh > _maxSpeed) {
        _maxSpeed = speedKmh;
      }

      if (speedKmh > _speedLimit && !_speedAlertSent) {
        _send('alert', '🚨 تحذير: تجاوز السرعة المسموحة! السيارة تسير بسرعة ${speedKmh.toInt()} كم/س', 
          lat: position.latitude, 
          lng: position.longitude
        );
        _speedAlertSent = true;
      } else if (speedKmh < (_speedLimit - 5)) {
        _speedAlertSent = false; 
      }

      if (_lastPosition != null) {
        double distanceInMeters = Geolocator.distanceBetween(
          _lastPosition!.latitude, _lastPosition!.longitude,
          position.latitude, position.longitude,
        );
        if (distanceInMeters < 500) { 
            _totalDistance += (distanceInMeters / 1000);
        }
      }
      _lastPosition = position;

      _dbRef.child('devices/$carId/trip_data').update({
        'current_speed': speedKmh.toInt(),
        'max_speed': _maxSpeed.toInt(), 
        'total_distance': _totalDistance,
        'avg_speed': speedKmh > 1 ? (_maxSpeed + speedKmh) / 2 : 0, 
        'lat': position.latitude,
        'lng': position.longitude,
        'last_update': ServerValue.timestamp,
      });
    });
  }

  void _listenForResetCommand(String carId) {
    _dbRef.child('devices/$carId/trip_data/total_distance').onValue.listen((event) {
      var val = event.snapshot.value;
      if (val == 0 || val == 0.0) {
        _totalDistance = 0.0;
        _maxSpeed = 0.0;
        _lastPosition = null;
      }
    });
  }

  Future<void> _startDirectCalling() async {
    if (_isCallingNow) return; 
    _isCallingNow = true;

    if (_emergencyNumbers.isEmpty) {
      _send('status', '❌ فشل: لا توجد أرقام طوارئ مخزنة');
      _isCallingNow = false;
      return;
    }

    for (int i = 0; i < _emergencyNumbers.length; i++) {
      if (!isSystemActive) break;
      String phone = _emergencyNumbers[i].trim();
      if (phone.isNotEmpty) {
        _send('status', '🚨 جاري الاتصال بالرقم (${i + 1}): $phone');
        try {
          await FlutterPhoneDirectCaller.callNumber(phone);
        } catch (e) {
          print("❌ خطأ اتصال: $e");
        }
        await Future.delayed(const Duration(seconds: 30));
      }
    }
    _isCallingNow = false;
  }

  void _send(String t, String m, {double? lat, double? lng}) async {
    if (myCarID == null) return;
    int batteryLevel = await Battery().batteryLevel;
    DateTime now = DateTime.now();
    String formattedTime = "${now.hour}:${now.minute.toString().padLeft(2, '0')}";
    String formattedDate = "${now.year}/${now.month}/${now.day}";
    String finalMessage = "$m\n🔋 $batteryLevel% | 🕒 $formattedTime | 📅 $formattedDate";

    String uniqueMsgId = DateTime.now().millisecondsSinceEpoch.toString();

    _dbRef.child('devices/$myCarID/responses').set({
      'id': uniqueMsgId,
      'type': t, 
      'message': finalMessage, 
      'lat': lat, 
      'lng': lng, 
      'timestamp': ServerValue.timestamp
    });
  }

  void _startEmergencyProtocol(double dist, double lat, double lng) {
    _send('alert', '🚨 خروج عن النطاق! تحركت السيارة ${dist.toInt()} متر', lat: lat, lng: lng);
    _startDirectCalling(); 
  }

  Future<void> stopSecuritySystem() async {
    _vibeSub?.cancel(); 
    _locSub?.cancel(); 
    _trackSub?.cancel(); 
    _sensSub?.cancel(); 
    _numsSub?.cancel(); 
    _vibeToggleSub?.cancel();
    _geoSub?.cancel();
    _positionStream?.cancel();
    _limitSub?.cancel(); 
    _testTimer?.cancel();
    _batteryStateSub?.cancel(); // إيقاف مراقبة الشاحن عند إطفاء النظام
    
    // إعادة ضبط الأعلام عند إيقاف النظام
    _isChargingSent = false;
    _isDischargingSent = false;

    isSystemActive = false;
    _isCallingNow = false;
    sLat = null; 
    sLng = null;

    await FlutterForegroundTask.stopService();
    
    if (myCarID != null) {
      await _dbRef.child('devices/$myCarID/system_active_status').set(false);
      SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool('was_system_active', false);
    }
    
    _send('status', '🔓 تم إيقاف النظام وتنظيف الذاكرة');
  }

  Future<void> sendLocation() async {
    Position p = await Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high);
    _send('location', '📍 تم تحديث الموقع بنجاح', lat: p.latitude, lng: p.longitude);
  }

  Future<void> sendBattery() async {
    _send('battery', '🔋 تحديث حالة الطاقة');
  }
}