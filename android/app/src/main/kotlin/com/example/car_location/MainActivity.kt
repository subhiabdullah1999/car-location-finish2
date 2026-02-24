package com.example.car_location

import android.content.Context
import android.content.Intent 
import android.net.wifi.WifiManager
import android.net.wifi.WifiConfiguration
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterFragmentActivity 
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterFragmentActivity() {
    private val CHANNEL = "hasba.security/hotspot"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            Log.d("HOTSPOT_DEBUG", "Method called: ${call.method}")
            
            when (call.method) {
                "enableHotspot" -> {
                    val status = toggleHotspot(true)
                    result.success(status)
                }
                "disableHotspot" -> {
                    val status = toggleHotspot(false)
                    result.success(status)
                }
                "getHotspotDetails" -> {
                    val details = getHotspotConfig()
                    result.success(details)
                }
                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    private fun toggleHotspot(enable: Boolean): String {
        Log.d("HOTSPOT_DEBUG", "Toggling Hotspot: $enable")
        
        // تم تصحيح الوصول هنا بحذف context()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            if (!android.provider.Settings.System.canWrite(this)) {
                val intent = Intent(android.provider.Settings.ACTION_MANAGE_WRITE_SETTINGS)
                intent.data = android.net.Uri.parse("package:$packageName")
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return "NEED_PERMISSION_UI"
            }
        }

        // استخدام applicationContext مباشرة
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        
        if (enable) wifiManager.isWifiEnabled = false

        val methods = wifiManager.javaClass.methods
        for (method in methods) {
            if (method.name == "setWifiApEnabled") {
                try {
                    if (method.parameterTypes.size == 2) {
                        method.invoke(wifiManager, null, enable)
                        return "SUCCESS"
                    } else if (method.parameterTypes.size == 1) {
                        method.invoke(wifiManager, enable)
                        return "SUCCESS"
                    }
                } catch (e: Exception) {
                    Log.e("HOTSPOT_DEBUG", "Reflection error: ${e.message}")
                }
            }
        }
        
        return try {
            val intent = Intent(Intent.ACTION_MAIN)
            intent.setClassName("com.android.settings", "com.android.settings.TetherSettings")
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            "OPENED_SETTINGS"
        } catch (e: Exception) {
            "ERROR: Could not find settings"
        }
    }

    private fun getHotspotConfig(): String {
        val wifiManager = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        return try {
            val method = wifiManager.javaClass.getMethod("getWifiApConfiguration")
            val config = method.invoke(wifiManager) as WifiConfiguration
            val ssid = config.SSID?.replace("\"", "") ?: "Unknown"
            val password = config.preSharedKey?.replace("\"", "") ?: "No Password"
            "Name: $ssid\nPass: $password"
        } catch (e: Exception) {
            Log.e("HOTSPOT_DEBUG", "Config Error: ${e.message}")
            "Unable to read details (Security Restriction)"
        }
    }
}