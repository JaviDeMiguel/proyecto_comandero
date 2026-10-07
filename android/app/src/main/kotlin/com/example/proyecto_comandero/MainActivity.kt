package com.example.proyecto_comandero

import android.content.Context
import android.net.wifi.WifiManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        try {
                            acquireMulticastLock()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("multicast_lock", e.message, null)
                        }
                    }
                    "release" -> {
                        releaseMulticastLock()
                        result.success(true)
                    }
                    "isHeld" -> result.success(multicastLock?.isHeld == true)
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDestroy() {
        releaseMulticastLock()
        super.onDestroy()
    }

    // Sin este lock muchos chipsets Wi-Fi filtran los datagramas UDP de broadcast,
    // y el host no recibiría los "probe" de descubrimiento de los comanderos.
    private fun acquireMulticastLock() {
        if (multicastLock?.isHeld == true) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock(LOCK_TAG).apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    private fun releaseMulticastLock() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }

    private companion object {
        const val CHANNEL = "proyecto_comandero/multicast_lock"
        const val LOCK_TAG = "tpv_comandero_discovery"
    }
}
