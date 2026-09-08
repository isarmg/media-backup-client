package org.sarmg.mediabackup

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.util.LruCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FilterOutputStream
import java.util.UUID

internal object RemoteImageCache {
    private var diskBytes = 256L * 1024 * 1024
    fun setLimit(context: Context, mib: Int) { diskBytes = mib.coerceIn(64,1024) * 1024L * 1024; context.getSharedPreferences("gallery-cache", 0).edit().putInt("limit_mib", mib).apply() }
    fun limit(context: Context): Int = context.getSharedPreferences("gallery-cache", 0).getInt("limit_mib", 256)
    fun clear(context: Context) { memory.evictAll(); context.cacheDir.listFiles()?.filter { it.name.startsWith("gallery-") }?.forEach { it.deleteRecursively() } }
    private val requests = Semaphore(3)
    private val memory = object : LruCache<String, Bitmap>(24 * 1024 * 1024) {
        override fun sizeOf(key: String, value: Bitmap) = value.allocationByteCount
    }
    suspend fun load(context: Context, api: BackupApi, profile: String, resource: RemoteResource, preview: Boolean): Bitmap? = requests.withPermit {
        withContext(Dispatchers.IO) {
            val key = "$profile/${resource.id}/$preview"
            memory.get(key)?.let { return@withContext it }
            require(resource.id.matches(Regex("[0-9a-fA-F-]{36}")))
            val root = File(context.cacheDir, "gallery-$profile").also { it.mkdirs() }
            diskBytes = limit(context) * 1024L * 1024
            val file = File(root, "${resource.id}-${if (preview) "preview-v1" else "thumbnail"}")
            if (!file.exists()) {
                val limit = if (preview) diskBytes else 8L * 1024 * 1024

                val temporary = File(root, "${UUID.randomUUID()}.part")
                try {
                    var derived = false
                    if (preview) {
                        try {
                            temporary.outputStream().use { output ->
                                var count = 0L
                                api.downloadCancellable("/v2/resources/${resource.id}/preview", object : FilterOutputStream(output) {
                                    override fun write(b: ByteArray, off: Int, len: Int) { count += len; check(count <= 8L * 1024 * 1024); out.write(b, off, len) }
                                    override fun write(b: Int) { count++; check(count <= 8L * 1024 * 1024); out.write(b) }
                                })
                            }
                            derived = true
                        } catch (e: kotlinx.coroutines.CancellationException) { throw e }
                        catch (_: Exception) { temporary.delete() }
                    }
                    if (!derived) {
                    require(resource.contentSize <= limit) { "原件过大，使用保存到手机下载" }
                    temporary.outputStream().use { output ->
                        var count = 0L
                        api.downloadCancellable(resource.contentPath, object : FilterOutputStream(output) {
                            override fun write(b: ByteArray, off: Int, len: Int) {
                                count += len; check(count <= limit) { "图片超过缓存上限" }; out.write(b, off, len)
                            }
                            override fun write(b: Int) { count++; check(count <= limit); out.write(b) }
                        })
                    }
                    }
                    check(temporary.renameTo(file)) { "无法保存预览缓存" }
                } finally { temporary.delete() }
            }
            file.setLastModified(System.currentTimeMillis())
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file.path, bounds)
            val max = if (preview) 2048 else 512
            var sample = 1
            while (bounds.outWidth / sample > max || bounds.outHeight / sample > max) sample *= 2
            val bitmap = BitmapFactory.decodeFile(file.path, BitmapFactory.Options().apply { inSampleSize = sample })
            bitmap?.let { memory.put(key, it) }
            val files = root.listFiles()?.filter { it.extension != "part" }?.sortedBy { it.lastModified() }.orEmpty()
            var bytes = files.sumOf { it.length() }
            for (old in files) { if (bytes <= diskBytes) break; if (old != file) { bytes -= old.length(); old.delete() } }
            bitmap
        }
    }
}
