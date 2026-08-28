package com.carriez.flutter_hbb

import android.content.Context
import android.util.Log
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

object InputTraceLog {
    private const val TAG = "input service"
    private const val LOG_DIR_NAME = "RustDesk/Logs/InputService"
    private const val LOG_FILE_NAME = "input_service.log"
    private val formatter = SimpleDateFormat("yyyy-MM-dd HH:mm:ss.SSS", Locale.US)
    private val lock = Any()

    fun filePath(context: Context): String {
        return File(resolveLogDir(context), LOG_FILE_NAME).absolutePath
    }

    fun d(context: Context?, message: String) {
        Log.d(TAG, message)
        append(context, "D", message)
    }

    fun i(context: Context?, message: String) {
        Log.i(TAG, message)
        append(context, "I", message)
    }

    fun w(context: Context?, message: String) {
        Log.w(TAG, message)
        append(context, "W", message)
    }

    fun e(context: Context?, message: String, throwable: Throwable? = null) {
        if (throwable == null) {
            Log.e(TAG, message)
        } else {
            Log.e(TAG, message, throwable)
        }
        append(context, "E", if (throwable == null) message else "$message ${throwable.message}")
    }

    private fun append(context: Context?, level: String, message: String) {
        if (context == null) {
            return
        }
        val line = "${formatter.format(Date())} [$level] $message\n"
        try {
            val dir = resolveLogDir(context)
            synchronized(lock) {
                File(dir, LOG_FILE_NAME).appendText(line)
            }
        } catch (e: Exception) {
            Log.e(TAG, "append input log failed", e)
        }
    }

    private fun resolveLogDir(context: Context): File {
        val baseDir = context.getExternalFilesDir(null) ?: context.filesDir
        val dir = File(baseDir, LOG_DIR_NAME)
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir
    }
}
