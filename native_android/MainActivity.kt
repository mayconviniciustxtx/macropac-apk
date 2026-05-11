package com.example.macropac_rastreamento

import android.content.Intent
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity: FlutterActivity() {
    private val CHANNEL = "macropac/native"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startTrackingService" -> {
                    try {
                        val intent = Intent(this, TrackingService::class.java)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success("servico_iniciado")
                    } catch (e: Exception) {
                        result.error("ERRO_START_SERVICE", e.message, null)
                    }
                }
                "stopTrackingService" -> {
                    try {
                        val intent = Intent(this, TrackingService::class.java)
                        stopService(intent)
                        result.success("servico_parado")
                    } catch (e: Exception) {
                        result.error("ERRO_STOP_SERVICE", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }
}
