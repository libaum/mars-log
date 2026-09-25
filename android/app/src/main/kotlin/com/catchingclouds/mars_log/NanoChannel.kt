package com.catchingclouds.marslog

import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/**
 * Gemini Nano through ML Kit's GenAI Prompt API (AICore), on the device.
 *
 * Replaces the `gemini_nano_android` plugin, which swallowed every error into
 * "not available", pinned an old API version and never downloaded the model.
 * Errors here reach Dart with the ML Kit error-code name as the code, so the
 * app can say *why* (background use, AICore outdated, model downloading …).
 *
 * Methods on channel `mars_log/nano`:
 * - `status` → "AVAILABLE" | "DOWNLOADABLE" | "DOWNLOADING" | "UNAVAILABLE"
 * - `download` → completes once the model is on the device
 * - `generate` {prompt, temperature, maxOutputTokens} → text of the first candidate
 */
class NanoChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "mars_log/nano")
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val model by lazy { Generation.getClient() }

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "status" -> run(result) { statusName(model.checkStatus()) }
            "download" -> run(result) {
                val end = model.download().first {
                    it is DownloadStatus.DownloadCompleted || it is DownloadStatus.DownloadFailed
                }
                if (end is DownloadStatus.DownloadFailed) throw end.e
                null
            }
            "generate" -> {
                val prompt = call.argument<String>("prompt") ?: ""
                val temp = call.argument<Number>("temperature")?.toFloat() ?: 0.4f
                val maxTokens = call.argument<Int>("maxOutputTokens") ?: 256
                run(result) {
                    val response = model.generateContent(
                        generateContentRequest(TextPart(prompt)) {
                            temperature = temp
                            maxOutputTokens = maxTokens
                        }
                    )
                    response.candidates.firstOrNull()?.text ?: ""
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun run(result: MethodChannel.Result, block: suspend () -> Any?) {
        scope.launch {
            try {
                result.success(block())
            } catch (e: GenAiException) {
                result.error(errorName(e.errorCode), e.message ?: e.toString(), null)
            } catch (e: Exception) {
                result.error("UNKNOWN", e.toString(), null)
            }
        }
    }

    private fun statusName(status: Int) = when (status) {
        FeatureStatus.AVAILABLE -> "AVAILABLE"
        FeatureStatus.DOWNLOADABLE -> "DOWNLOADABLE"
        FeatureStatus.DOWNLOADING -> "DOWNLOADING"
        else -> "UNAVAILABLE"
    }

    private fun errorName(code: Int) = when (code) {
        GenAiException.ErrorCode.NOT_AVAILABLE -> "NOT_AVAILABLE"
        GenAiException.ErrorCode.BUSY -> "BUSY"
        GenAiException.ErrorCode.NOT_SUPPORTED -> "NOT_SUPPORTED"
        GenAiException.ErrorCode.BACKGROUND_USE_BLOCKED -> "BACKGROUND_USE_BLOCKED"
        GenAiException.ErrorCode.PER_APP_BATTERY_USE_QUOTA_EXCEEDED -> "QUOTA_EXCEEDED"
        GenAiException.ErrorCode.NOT_ENOUGH_DISK_SPACE -> "NOT_ENOUGH_DISK_SPACE"
        GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE -> "NEEDS_SYSTEM_UPDATE"
        GenAiException.ErrorCode.AICORE_INCOMPATIBLE -> "AICORE_INCOMPATIBLE"
        GenAiException.ErrorCode.REQUEST_TOO_LARGE -> "REQUEST_TOO_LARGE"
        GenAiException.ErrorCode.CANCELLED -> "CANCELLED"
        else -> "GENAI_$code"
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }
}
