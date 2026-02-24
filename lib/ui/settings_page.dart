import 'package:car_location/ui/about_app.dart';
import 'package:car_location/ui/developer_page.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:car_location/main.dart'; 
import 'package:car_location/ui/type_selctor_page.dart'; 
import 'package:url_launcher/url_launcher.dart';
import 'package:local_auth/local_auth.dart'; // المكتبة الجديدة للبصمة

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _isDarkMode = false;
  bool _isBiometricEnabled = false; // حالة قفل البصمة
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  // تحميل كافة الإعدادات المحفوظة
  void _loadSettings() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      _isDarkMode = prefs.getBool('dark_mode') ?? false;
      _isBiometricEnabled = prefs.getBool('biometric_enabled') ?? false;
    });
  }

  // دالة تغيير الثيم وحفظه
  void _toggleTheme(bool value) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('dark_mode', value);
    setState(() {
      _isDarkMode = value;
    });
    themeNotifier.value = value ? ThemeMode.dark : ThemeMode.light;
  }

  // دالة تفعيل/تعطيل قفل البصمة
  void _toggleBiometric(bool value) async {
    bool canCheck = await _auth.canCheckBiometrics || await _auth.isDeviceSupported();
    
    if (!canCheck && value == true) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("عذراً، جهازك لا يدعم تقنية البصمة"))
      );
      return;
    }

    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool('biometric_enabled', value);
    setState(() {
      _isBiometricEnabled = value;
    });
  }

  // مسح سجل الإشعارات (تم التعديل لضمان التحديث الفوري)
  void _clearNotifications() async {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("تأكيد المسح"),
        content: const Text("هل تريد حذف سجل الإشعارات المحفوظ على هذا الجهاز؟"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("إلغاء")),
          TextButton(
            onPressed: () async {
              SharedPreferences prefs = await SharedPreferences.getInstance();
              String? carID = prefs.getString('car_id');
              
              await prefs.remove('saved_notifs_$carID');
              await prefs.setInt('unread_count_$carID', 0);
              
              if (mounted) {
                Navigator.pop(ctx);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text("تم مسح السجل وتصفير العداد بنجاح"))
                );
              }
            }, 
            child: const Text("حذف الآن", style: TextStyle(color: Colors.red))
          ),
        ],
      ),
    );
  }

  // تغيير معرف السيارة
  void _resetCarID() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('car_id');
    if (mounted) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (context) => const AppTypeSelector()), 
        (route) => false
      );
    }
  }

  Widget _buildOption(IconData icon, String title, String subtitle, Color color, VoidCallback onTap) {
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: color.withOpacity(0.1),
          child: Icon(icon, color: color),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        onTap: onTap,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("الإعدادات"),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 20),
            
            // 1. كرت الوضع الداكن
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              child: SwitchListTile(
                secondary: Icon(
                  _isDarkMode ? Icons.dark_mode : Icons.light_mode,
                  color: _isDarkMode ? Colors.amber : Colors.blue,
                ),
                title: const Text("الوضع الداكن", style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: Text(_isDarkMode ? "تفعيل المظهر الأسود" : "تفعيل المظهر الفاتح"),
                value: _isDarkMode,
                onChanged: _toggleTheme,
              ),
            ),

            // 2. كرت قفل البصمة
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              child: SwitchListTile(
                secondary: Icon(
                  Icons.fingerprint,
                  color: _isBiometricEnabled ? Colors.teal : Colors.grey,
                ),
                title: const Text("قفل التطبيق", style: TextStyle(fontWeight: FontWeight.bold)),
                subtitle: const Text("طلب البصمة عند فتح التطبيق"),
                value: _isBiometricEnabled,
                onChanged: _toggleBiometric,
              ),
            ),

            const Divider(height: 30, indent: 20, endIndent: 20),

            // 3. إدارة البيانات
            _buildOption(
              Icons.delete_sweep_outlined, 
              "إدارة البيانات", 
              "مسح سجل الإشعارات المحفوظ", 
              Colors.redAccent, 
              _clearNotifications
            ),

            // 4. تغيير السيارة
            _buildOption(
              Icons.directions_car_filled_outlined, 
              "تغيير السيارة", 
              "التبديل إلى معرف سيارة آخر", 
              Colors.green, 
              _resetCarID
            ),

            // 5. ميزة "حول التطبيق" الجديدة
            _buildOption(
              Icons.info_outline_rounded, 
              "حول التطبيق", 
              "تعرف على مهام ونظام HASBA TRACKER", 
              Colors.blueGrey, 
              () {
                Navigator.push(context, MaterialPageRoute(builder: (context) => const AboutAppPage()));
              }
            ),

            // كرت مطور التطبيق
            _buildOption(
              Icons.code_rounded, 
              "مطور التطبيق", 
              "تعرف على المطور ووسائل التواصل", 
              Colors.deepPurple, 
              () {
                Navigator.push(context, MaterialPageRoute(builder: (context) => const DeveloperPage()));
              }
            ),

            const SizedBox(height: 10),

            // 6. الدعم الفني
            _buildOption(
              Icons.support_agent_outlined, 
              "الدعم الفني", 
              "تواصل معنا للمساعدة عبر واتساب", 
              Colors.orange, 
              () => launchUrl(Uri.parse("https://wa.me/+905396617266")) 
            ),

            const SizedBox(height: 10),

            // 7. كرت إصدار التطبيق
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
              child: const ListTile(
                leading: Icon(Icons.verified_outlined, color: Colors.grey),
                title: Text("إصدار التطبيق"),
                trailing: Text("v2.5.0", style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
              ),
            ),

            const SizedBox(height: 40),
            
            Text(
              "HASBA TRACKER SECURITY SYSTEM",
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12, letterSpacing: 1.2),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

