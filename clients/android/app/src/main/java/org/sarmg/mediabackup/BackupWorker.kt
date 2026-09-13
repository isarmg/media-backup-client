package org.sarmg.mediabackup

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import org.json.JSONObject
import java.io.File

class BackupWorker(context: Context, parameters: WorkerParameters) : CoroutineWorker(context, parameters) {
    override suspend fun doWork(): Result {
        backupMutex.lock()
        return try {
            withContext(Dispatchers.IO) { runBackup() }
        } finally {
            backupMutex.unlock()
        }
    }

    private suspend fun runBackup(): Result {
        val config = SecureConfig(applicationContext)
        val profile = inputData.getString("profile") ?: return Result.failure()
        val credentials = config.connection()
        if (profile != credentials.profile) return Result.failure()
        val automatic = inputData.getString(BackupScheduler.SOURCE_KEY) == BackupScheduler.SOURCE_AUTOMATIC
        if (automatic && !config.autoBackup) return Result.success()
        val session = TransferStore.open(applicationContext, profile)
        val handle = session.handle
        val staging = session.paths.staging
        var snapshot = BackupSnapshot(state = "running", message = "正在准备备份", lastRunAt = System.currentTimeMillis())
        try {
            val api = BackupApi(credentials.server, credentials.token)
            check(credentials.token.isNotBlank() && credentials.accountId.isNotBlank() && credentials.deviceId.isNotBlank()) {
                "客户端需要使用当前实例授权码重新配对"
            }
            val accountId = credentials.accountId
            val deviceId = credentials.deviceId
            TransferStore.command(handle, "bind", JSONObject().put("server", credentials.server)
                .put("account_id", accountId).put("device_id", deviceId))
            var resourceCount = 0
            suspend fun drain() {
                while (!isStopped && config.profile == profile && resourceCount < MAX_UPLOAD_ITEMS) {
                    val envelope = MobileContractV02.requireEnvelope(NativeBridgeV2.next(handle, staging.path))
                    if (envelope.isNull("value")) break
                    val job = envelope.getJSONObject("value")
                    MobileContractV02.requireIdentity(job)
                    snapshot = snapshot.copy(message = "正在上传：${job.getJSONObject("request").getString("filename")}")
                    publish(config, snapshot, "上传资源", 0, 0)
                    snapshot = snapshot.copy(uploadedBytes = snapshot.uploadedBytes + uploadJob(api, handle, job))
                    resourceCount++
                }
            }
            // Always consume durable work first. Manual entry never invokes the automatic scanner.
            drain()
            val batches = TransferStore.batches(handle)
            for (b in 0 until batches.length()) {
                val batch = batches.getJSONObject(b)
                if (batch.getBoolean("cancelled")) continue
                val batchId = batch.getString("id")
                val items = TransferStore.items(handle, batchId)
                for (i in 0 until items.length()) {
                    if (isStopped || config.profile != profile) return Result.failure()
                    if (resourceCount >= MAX_UPLOAD_ITEMS) return Result.retry()
                    val item = items.getJSONObject(i)
                    if (item.getString("state") != "pending") continue
                    // Recheck cancellation after each resource and before preparing another source.
                    if (TransferStore.items(handle, batchId).length() == 0) break
                    try {
                        snapshot = snapshot.copy(message = "正在准备所选原始文件")
                        publish(config, snapshot, "准备", 0, 0)
                        SelectedMedia.prepare(applicationContext, handle, staging, batchId, item)
                    } catch (error: Exception) {
                        TransferStore.setItem(handle, batchId, item.getString("id"), "blocked",
                            error.message ?: "需要重新授权访问")
                    }
                    drain()
                }
            }
            var automaticMore = false
            if (automatic) {
                if (!hasMediaAccess(config)) {
                    config.saveSnapshot(snapshot.copy(state = "waiting", message = "自动扫描需要重新授权访问"))
                    return Result.success()
                }
                // Bounded scan/export windows: at most one asset is staged before draining.
                for (attempt in 0 until MAX_SCAN_ITEMS) {
                    if (isStopped || config.profile != profile) return Result.failure()
                    if (resourceCount >= MAX_UPLOAD_ITEMS) return Result.retry()
                    val scan = MediaScanner(applicationContext).scan(handle, staging, ScanOptions(
                        config.backupPhotos, config.backupVideos, config.cameraOnly, config.selectedAlbumIds, 1))
                    drain()
                    for ((id, album) in scan.albums) {
                        api.syncAlbum(id, album.name, album.sourceAssetIds, replaceMembers = false)
                    }
                    if (scan.error != null) {
                        config.saveSnapshot(snapshot.copy(state = "waiting", message = scan.error))
                        return Result.success()
                    }
                    automaticMore = scan.limitReached
                    if (!scan.limitReached) break
                }
            }
            if (config.profile != profile) return Result.failure()
            val stats = MobileContractV02.requireEnvelope(NativeBridgeV2.stats(handle)).getJSONObject("value")
            val waiting = automaticMore || stats.getLong("retry_wait") > 0 || stats.getLong("ready") > 0 || stats.getLong("discovered") > 0
            config.saveSnapshot(snapshot.copy(state = if (waiting) "waiting" else "success",
                message = if (waiting) "等待网络或系统重试；逐项结果见传输列表" else "本轮处理结束；逐项结果见传输列表",
                lastSuccessAt = if (waiting) 0 else System.currentTimeMillis()))
            return if (waiting) Result.retry() else Result.success()
        } catch (error: kotlinx.coroutines.CancellationException) {
            throw error
        } catch (error: Exception) {
            if (config.profile == profile) config.saveSnapshot(snapshot.copy(state = "waiting",
                message = error.message ?: "等待网络或系统调度"))
            return Result.retry()
        }
    }

    private fun uploadJob(api: BackupApi, handle: Long, job: JSONObject): Long {
        val jobId = job.getString("job_id")
        try {
            val create = api.createUpload(job.getJSONObject("request").toString())
            if (create.getString("disposition") == "complete") {
                TransferStore.receipt(handle, job, api.manifest(create.getString("resource_id")))
                return 0L
            }
            val uploadId = create.getString("upload_id")
            MobileContractV02.requireEnvelope(NativeBridgeV2.markUpload(handle, jobId, uploadId))
            val files = mutableMapOf<Int, File>()
            val localParts = job.getJSONArray("local_parts")
            for (position in 0 until localParts.length()) {
                val part = localParts.getJSONObject(position)
                files[part.getInt("index")] = File(part.getString("path"))
            }
            val missing = create.getJSONArray("missing_parts")
            var uploadedBytes = 0L
            for (position in 0 until missing.length()) {
                val index = missing.getInt(position)
                val file = files[index] ?: error("缺少本地分块 $index")
                if (isStopped || SecureConfig(applicationContext).profile != inputData.getString("profile") ||
                    TransferStore.command(handle, "active", JSONObject().put("job_id", jobId)) != true) {
                    error("本次上传已取消或账户已切换")
                }
                api.uploadPart(uploadId, index, file)
                uploadedBytes += file.length()
                MobileContractV02.requireEnvelope(NativeBridgeV2.markPart(handle, jobId, index))
            }
            TransferStore.receipt(handle, job, api.complete(uploadId))
            return uploadedBytes
        } catch (error: Exception) {
            MobileContractV02.requireEnvelope(
                NativeBridgeV2.markFailed(handle, jobId, error.message ?: "上传失败", true),
            )
            throw error
        }
    }

    private suspend fun publish(
        config: SecureConfig,
        snapshot: BackupSnapshot,
        stage: String,
        completed: Int,
        total: Int,
    ) {
        config.saveSnapshot(snapshot)
        setProgress(
            workDataOf(
                PROGRESS_STAGE to stage,
                PROGRESS_MESSAGE to snapshot.message,
                PROGRESS_COMPLETED to completed,
                PROGRESS_TOTAL to total,
                PROGRESS_ITEM to snapshot.currentItem,
            ),
        )
        setForeground(createForegroundInfo(snapshot.message, completed, total))
    }

    private fun hasMediaAccess(config: SecureConfig): Boolean {
        if (Build.VERSION.SDK_INT < 33) {
            return ContextCompat.checkSelfPermission(
                applicationContext,
                android.Manifest.permission.READ_EXTERNAL_STORAGE,
            ) == PackageManager.PERMISSION_GRANTED
        }
        val partial = Build.VERSION.SDK_INT >= 34 && ContextCompat.checkSelfPermission(
            applicationContext,
            android.Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED,
        ) == PackageManager.PERMISSION_GRANTED
        val photosAllowed = !config.backupPhotos || partial || ContextCompat.checkSelfPermission(
            applicationContext,
            android.Manifest.permission.READ_MEDIA_IMAGES,
        ) == PackageManager.PERMISSION_GRANTED
        val videosAllowed = !config.backupVideos || partial || ContextCompat.checkSelfPermission(
            applicationContext,
            android.Manifest.permission.READ_MEDIA_VIDEO,
        ) == PackageManager.PERMISSION_GRANTED
        return photosAllowed && videosAllowed
    }

    private fun createForegroundInfo(message: String, completed: Int, total: Int): ForegroundInfo {
        val manager = applicationContext.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL_ID, "媒体备份", NotificationManager.IMPORTANCE_LOW))
        val contentIntent = PendingIntent.getActivity(
            applicationContext,
            0,
            Intent(applicationContext, MainActivity::class.java),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = NotificationCompat.Builder(applicationContext, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentTitle("媒体备份")
            .setContentText(message)
            .setContentIntent(contentIntent)
            .setOnlyAlertOnce(true)
            .setOngoing(true)
            .setProgress(maxOf(total, 1), completed.coerceAtMost(maxOf(total, 1)), total <= 0)
            .build()
        return if (Build.VERSION.SDK_INT >= 29) {
            ForegroundInfo(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        const val PROGRESS_STAGE = "stage"
        const val PROGRESS_MESSAGE = "message"
        const val PROGRESS_COMPLETED = "completed"
        const val PROGRESS_TOTAL = "total"
        const val PROGRESS_ITEM = "item"
        const val OUTPUT_MESSAGE = "result_message"

        private const val CHANNEL_ID = MobileContractV02.NOTIFICATION_CHANNEL
        private const val NOTIFICATION_ID = 4102
        private const val MAX_SCAN_ITEMS = 40
        private const val MAX_UPLOAD_ITEMS = 60
        private val backupMutex = Mutex()
    }
}
