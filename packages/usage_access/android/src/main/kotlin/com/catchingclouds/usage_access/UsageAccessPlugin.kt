package com.catchingclouds.usage_access

import android.app.AppOpsManager
import android.app.usage.UsageEvents
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlin.concurrent.thread

/**
 * Raw usage events and app labels from [UsageStatsManager]. No aggregation:
 * Mars Log stores what Android hands out, because Android itself forgets it
 * after about a week.
 */
class UsageAccessPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "mars_log/usage_access")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "hasAccess" -> result.success(hasAccess())
            "openAccessSettings" -> {
                openAccessSettings()
                result.success(null)
            }
            "queryEvents" -> {
                val begin = (call.argument<Number>("begin"))!!.toLong()
                val end = (call.argument<Number>("end"))!!.toLong()
                val types = call.argument<List<Number>>("types")!!.map { it.toInt() }.toSet()
                // Off the platform thread: a week of events takes a moment.
                thread {
                    try {
                        val events = queryEvents(begin, end, types)
                        main.post { result.success(events) }
                    } catch (e: Exception) {
                        main.post { result.error("query_failed", e.message, null) }
                    }
                }
            }
            "appLabels" -> {
                val packages = call.argument<List<String>>("packages")!!
                result.success(appLabels(packages))
            }
            else -> result.notImplemented()
        }
    }

    private fun hasAccess(): Boolean {
        val ops = context.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow(AppOpsManager.OPSTR_GET_USAGE_STATS, Process.myUid(), context.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    /** Straight to this app's switch where the system offers that, else the list. */
    private fun openAccessSettings() {
        val intent = Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
            .setData(Uri.parse("package:${context.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (_: Exception) {
            context.startActivity(
                Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
        }
    }

    /**
     * Events in [begin, end) of the given [types], as `packages` (each name
     * once) and `events`, a flat list of `timestamp, type, packageIndex`
     * triples — compact over the channel, a week can be tens of thousands.
     */
    private fun queryEvents(begin: Long, end: Long, types: Set<Int>): Map<String, Any> {
        val manager = context.getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
        val packages = mutableListOf<String>()
        val index = HashMap<String, Int>()
        val events = ArrayList<Long>()
        val usage = manager.queryEvents(begin, end) ?: return mapOf("packages" to packages, "events" to LongArray(0))
        val event = UsageEvents.Event()
        while (usage.hasNextEvent()) {
            usage.getNextEvent(event)
            if (event.eventType !in types) continue
            val pkg = event.packageName ?: ""
            val i = index.getOrPut(pkg) { packages.add(pkg); packages.size - 1 }
            events.add(event.timeStamp)
            events.add(event.eventType.toLong())
            events.add(i.toLong())
        }
        return mapOf("packages" to packages, "events" to events.toLongArray())
    }

    /** Display names; a package this app may not see is left out. */
    private fun appLabels(packages: List<String>): Map<String, String> {
        val pm = context.packageManager
        val labels = HashMap<String, String>()
        for (pkg in packages) {
            try {
                labels[pkg] = pm.getApplicationLabel(pm.getApplicationInfo(pkg, 0)).toString()
            } catch (_: PackageManager.NameNotFoundException) {
            }
        }
        return labels
    }
}
