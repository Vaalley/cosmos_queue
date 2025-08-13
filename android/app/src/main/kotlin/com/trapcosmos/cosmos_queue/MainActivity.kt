package com.trapcosmos.cosmos_queue

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.util.Log

class MainActivity: FlutterActivity() {
    private val channelName = "cosmos_queue/share"
    private var methodChannel: MethodChannel? = null
    private var initialSharedText: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        Log.d("CosmosQueue", "MethodChannel configured")
        methodChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialSharedText" -> {
                    Log.d("CosmosQueue", "getInitialSharedText called; returning ${'$'}initialSharedText")
                    result.success(initialSharedText)
                    initialSharedText = null
                }
                "completeShare" -> {
                    Log.d("CosmosQueue", "completeShare received; finishing activity")
                    result.success(null)
                    finishAndRemoveTask()
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleShareIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleShareIntent(intent)
    }

    private fun handleShareIntent(intent: Intent?) {
        if (intent == null) return
        val action = intent.action
        val type = intent.type
        Log.d("CosmosQueue", "handleShareIntent: action=${'$'}action type=${'$'}type")
        if (Intent.ACTION_SEND == action && type == "text/plain") {
            val sharedText = intent.getStringExtra(Intent.EXTRA_TEXT)
            Log.d("CosmosQueue", "Shared text received: ${'$'}sharedText")
            if (!sharedText.isNullOrEmpty()) {
                if (methodChannel == null) {
                    Log.d("CosmosQueue", "MethodChannel null; caching initialSharedText")
                    initialSharedText = sharedText
                } else {
                    Log.d("CosmosQueue", "Sending sharedText over MethodChannel")
                    methodChannel?.invokeMethod("sharedText", sharedText)
                }
            }
        }
    }
}
