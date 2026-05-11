package com.example.macropac_rastreamento

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.os.Build
import android.os.IBinder
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

class TrackingService : Service() {
    private val channelId = "macropac_tracking_channel"
    private val notificationId = 7788
    private lateinit var fused: FusedLocationProviderClient
    private var callback: LocationCallback? = null

    override fun onCreate() {
        super.onCreate()
        fused = LocationServices.getFusedLocationProviderClient(this)
        criarCanal()
        startForeground(notificationId, criarNotificacao("Rastreamento ativo"))
        iniciarGps()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        iniciarGps()
        return START_STICKY
    }

    override fun onDestroy() {
        callback?.let { fused.removeLocationUpdates(it) }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun criarCanal() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val canal = NotificationChannel(channelId, "Macropac Rastreamento", NotificationManager.IMPORTANCE_LOW)
            canal.description = "Rastreamento de frota em segundo plano"
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(canal)
        }
    }

    private fun criarNotificacao(texto: String): Notification {
        return NotificationCompat.Builder(this, channelId)
            .setContentTitle("Macropac Rastreamento")
            .setContentText(texto)
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun atualizarNotificacao(texto: String) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.notify(notificationId, criarNotificacao(texto))
    }

    private fun iniciarGps() {
        if (ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION) != PackageManager.PERMISSION_GRANTED &&
            ActivityCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION) != PackageManager.PERMISSION_GRANTED) {
            atualizarNotificacao("Permissão de localização pendente")
            return
        }

        if (callback != null) return

        val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, 15000L)
            .setMinUpdateIntervalMillis(10000L)
            .setMaxUpdateDelayMillis(20000L)
            .build()

        callback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                val location = result.lastLocation ?: return
                enviarLocalizacao(location)
            }
        }

        fused.requestLocationUpdates(request, callback!!, Looper.getMainLooper())
    }

    private fun token(): String {
        val prefs = getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        return prefs.getString("flutter.token", "") ?: ""
    }

    private fun enviarLocalizacao(location: Location) {
        Thread {
            try {
                val t = token()
                if (t.isEmpty()) {
                    atualizarNotificacao("Aguardando login")
                    return@Thread
                }

                val params = linkedMapOf(
                    "token" to t,
                    "latitude" to location.latitude.toString(),
                    "longitude" to location.longitude.toString(),
                    "velocidade" to if (location.hasSpeed()) location.speed.toString() else "",
                    "precisao" to if (location.hasAccuracy()) location.accuracy.toString() else "",
                    "bateria" to "",
                    "origem" to "apk_native_background"
                )

                val body = params.map {
                    URLEncoder.encode(it.key, "UTF-8") + "=" + URLEncoder.encode(it.value, "UTF-8")
                }.joinToString("&")

                val url = URL("https://mega4tech.com.br/macropac_rastreamento/api/app_salvar_localizacao.php")
                val conn = url.openConnection() as HttpURLConnection
                conn.requestMethod = "POST"
                conn.doOutput = true
                conn.connectTimeout = 20000
                conn.readTimeout = 20000
                conn.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")

                OutputStreamWriter(conn.outputStream).use {
                    it.write(body)
                    it.flush()
                }

                val code = conn.responseCode
                if (code in 200..299) {
                    atualizarNotificacao("Localização enviada")
                } else {
                    atualizarNotificacao("Erro ao enviar: $code")
                }
                conn.disconnect()
            } catch (e: Exception) {
                atualizarNotificacao("Tentando enviar localização")
            }
        }.start()
    }
}
