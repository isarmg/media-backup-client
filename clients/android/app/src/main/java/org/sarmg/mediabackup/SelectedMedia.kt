package org.sarmg.mediabackup

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

internal object SelectedMedia {
    // Reserve room for chunk preparation as well as the source. Process one item at a time.
    private const val MAX_SOURCE_BYTES = 2L * 1024 * 1024 * 1024

    fun persist(context: Context, profile: String, uris: List<Uri>): String {
        val session = TransferStore.open(context, profile)
        val batch = UUID.randomUUID().toString()
        val items = JSONArray()
        for (uri in uris.distinct()) {
            runCatching { context.contentResolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            var name = "媒体"
            context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                if (it.moveToFirst()) name = it.getString(0) ?: name
            }
            items.put(JSONObject().put("id", UUID.randomUUID().toString()).put("source",
                JSONObject().put("uri", uri.toString()).put("name", name).toString()))
        }
        TransferStore.command(session.handle, "create_batch", JSONObject().put("id", batch).put("items", items))
        return batch
    }

    fun prepare(context: Context, handle: Long, staging: File, batch: String, item: JSONObject) {
        val descriptor = JSONObject(item.getString("source"))
        val uri = Uri.parse(descriptor.getString("uri"))
        val resolver = context.contentResolver
        var name = "media"
        var size = -1L
        resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst()) {
                name = it.getString(0) ?: name
                if (!it.isNull(1)) size = it.getLong(1)
            }
        }
        val mime = resolver.getType(uri) ?: error("无法读取媒体类型，需要重新选择")
        require(mime.startsWith("image/") || mime.startsWith("video/")) { "请选择照片或视频" }
        val sourceDir = File(staging, "sources").also { check(it.mkdirs() || it.isDirectory) }
        val budget = minOf(MAX_SOURCE_BYTES, (sourceDir.usableSpace - 128L * 1024 * 1024) / 2)
        check(budget > 0 && (size < 0 || size <= budget)) { "暂存空间不足；单项上限 2 GiB，请释放空间后重试" }
        val output = File(sourceDir, UUID.randomUUID().toString())
        var primaryQueued = false
        try {
            resolver.openInputStream(uri)?.use { input ->
                output.outputStream().use { target ->
                    val buffer = ByteArray(64 * 1024)
                    var copied = 0L
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        copied += n
                        check(copied <= budget) { "媒体超过暂存预算" }
                        target.write(buffer, 0, n)
                    }
                }
            } ?: error("需要重新授权访问所选媒体")
            // Picker URI aliases are not assumed to be MediaStore identities. Hash the delivered
            // bytes for a stable import identity, including across provider URI changes.
            val digest = java.security.MessageDigest.getInstance("SHA-256")
            output.inputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
            }
            val source = descriptor.optString("source_id").takeIf { it.isNotEmpty() }
                ?: ("android-import:" + digest.digest().joinToString("") { "%02x".format(it) })
            val modifiedMs = descriptor.optLong("modified_ms", 0)
            TransferStore.gallery(handle, "declare_resources", JSONObject().put("source_id", source).put("modified_ms", modifiedMs).put("originals", 1))
            TransferStore.command(handle, "alias", JSONObject().put("alias", "$uri#$source").put("source_id", source))
            var createdMs = System.currentTimeMillis()
            runCatching {
                resolver.query(uri, arrayOf("datetaken", "date_added"), null, null, null)?.use {
                    if (it.moveToFirst()) createdMs = if (!it.isNull(0) && it.getLong(0) > 0) it.getLong(0) else it.getLong(1) * 1000
                }
            }
            val kind = if (mime.startsWith("video/")) "video" else "photo"
            val scanner = MediaScanner(context)
            val itemId = item.getString("id")
            fun linked(resource: String): Boolean = TransferStore.command(handle, "link_resource", JSONObject()
                .put("batch_id", batch).put("item_id", itemId).put("asset", source).put("resource", resource).put("modified_ms", modifiedMs)) == true
            if (!linked(source)) {
                scanner.enqueue(handle, source, source, kind, "primary", output, name, mime,
                    createdMs, modifiedMs, JSONObject().put("import_copy", !descriptor.has("source_id")), true, batch, itemId)
                primaryQueued = true
            }
            val thumbnailId = "$source#thumbnail-v1"
            if (!linked(thumbnailId)) {
                scanner.createThumbnail(output, kind, sourceDir)?.let { thumbnail ->
                    scanner.enqueue(handle, source, thumbnailId, kind, "thumbnail", thumbnail, "$name.thumbnail.jpg", "image/jpeg",
                        createdMs, modifiedMs, JSONObject().put("thumbnail_of", source), true, batch, itemId)
                }
            }
            TransferStore.setItem(handle, batch, itemId, "queued")
        } finally {
            if (!primaryQueued) output.delete()
        }
    }
}
