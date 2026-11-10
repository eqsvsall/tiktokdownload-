package com.cryfsall.tikdl

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val channelName = "cfs/native"
    private val chDone = "dl_done"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        createChannel()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestNotif" -> {
                        if (Build.VERSION.SDK_INT >= 33 &&
                            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
                        ) {
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
                        }
                        result.success(null)
                    }

                    "notify" -> {
                        val id = call.argument<Int>("id") ?: 1
                        val title = call.argument<String>("title") ?: ""
                        val body = call.argument<String>("body") ?: ""
                        notify(id, title, body)
                        result.success(null)
                    }

                    "saveToDownloads" -> {
                        val path = call.argument<String>("path")
                        val name = call.argument<String>("name") ?: "tiktok.mp4"
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        if (path == null) {
                            result.error("ARG", "path kosong", null)
                        } else {
                            Thread {
                                try {
                                    val where = saveToDownloads(File(path), name, mime)
                                    runOnUiThread { result.success(where) }
                                } catch (e: Exception) {
                                    runOnUiThread { result.error("SAVE", e.message, null) }
                                }
                            }.start()
                        }
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= 26) {
            val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.createNotificationChannel(
                NotificationChannel(chDone, "Download", NotificationManager.IMPORTANCE_DEFAULT)
            )
        }
    }

    private fun notify(id: Int, title: String, body: String) {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val b = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, chDone)
        else @Suppress("DEPRECATION") Notification.Builder(this)
        b.setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
        nm.notify(id, b.build())
    }

    private fun saveToDownloads(src: File, name: String, mime: String): String {
        if (Build.VERSION.SDK_INT >= 29) {
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, name)
                put(MediaStore.Downloads.MIME_TYPE, mime)
                put(MediaStore.Downloads.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/TikTokDownloader")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val resolver = contentResolver
            val uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
                ?: throw Exception("Gagal membuat file di Downloads")
            resolver.openOutputStream(uri).use { out ->
                FileInputStream(src).use { input -> input.copyTo(out!!) }
            }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            return "Download/TikTokDownloader/$name"
        } else {
            // Android 9 ke bawah: simpan di folder app (tanpa izin storage)
            val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
                ?: throw Exception("Storage tidak tersedia")
            val dest = File(dir, name)
            src.copyTo(dest, overwrite = true)
            return dest.absolutePath
        }
    }
}
