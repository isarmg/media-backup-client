package org.sarmg.mediabackup

import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.provider.MediaStore
import org.json.JSONObject

data class RemoteResource(
    val id: String,
    val role: String,
    val filename: String,
    val mimeType: String,
    val contentPath: String,
    val contentSize: Long,
    val metadata: JSONObject?,
)

data class RemoteAsset(
    val id: String,
    val createdAtMs: Long,
    val mediaKind: String,
    val favorite: Boolean,
    val archived: Boolean,
    val trashed: Boolean,
    val tagNames: List<String>,
    val resources: List<RemoteResource>,
)

object RemoteLibrary {
    data class Page(val items: List<RemoteAsset>, val nextCursor: String?, val cached: Boolean = false)

    fun loadTimelinePage(api: BackupApi, cursor: String? = null, trashed: Boolean = false,
        favorite: Boolean = false, albumId: String? = null): Page {
        val page = api.timeline(cursor, trashed, favorite, albumId)
        val items = page.getJSONArray("items")
        val next = page.optString("next_cursor").takeIf { it.isNotBlank() && it != "null" }
        check(next == null || next != cursor) { "服务器返回了无效的分页游标" }
        return Page(buildList { for (i in 0 until items.length()) add(parseAsset(items.getJSONObject(i))) }, next)
    }

    fun restore(context: Context, api: BackupApi, asset: RemoteAsset, profile: String): String {
        val resource = asset.resources.firstOrNull { it.role == "primary" }
            ?: asset.resources.firstOrNull { it.role != "thumbnail" }
            ?: error("该资产没有可恢复的原始资源")
        val collection = if (resource.mimeType.startsWith("video/")) {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, resource.filename)
            put(MediaStore.MediaColumns.MIME_TYPE, resource.mimeType)
            if (Build.VERSION.SDK_INT >= 29) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, "Pictures/MediaBackup Restored")
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }
        val uri = context.contentResolver.insert(collection, values) ?: error("无法创建恢复文件")
        val transfer = DownloadTransfers.start(profile, resource.filename, resource.contentSize)
        try {
            context.contentResolver.openOutputStream(uri)?.use { output ->
                var bytes = 0L; var reported = 0L
                api.download(resource.contentPath, object : java.io.FilterOutputStream(output) {
                    override fun write(buffer: ByteArray, off: Int, len: Int) {
                        out.write(buffer, off, len); bytes += len
                        if (bytes - reported >= 256 * 1024) { DownloadTransfers.update(transfer, bytes); reported = bytes }
                    }
                    override fun write(value: Int) { out.write(value); bytes++ }
                })
                check(bytes == resource.contentSize) { "原件下载长度不匹配" }
                DownloadTransfers.update(transfer, bytes)
            }
                ?: error("无法打开恢复文件")
            if (Build.VERSION.SDK_INT >= 29) {
                context.contentResolver.update(uri, ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }, null, null)
            }
            DownloadTransfers.update(transfer, phase = "已保存到手机")
            return resource.filename
        } catch (error: Exception) {
            DownloadTransfers.update(transfer, phase = "下载失败：${error.message}")
            context.contentResolver.delete(uri, null, null)
            throw error
        }
    }

    fun thumbnail(api: BackupApi, asset: RemoteAsset): ByteArray? {
        val resource = asset.resources.firstOrNull { it.role == "thumbnail" }
            ?: return null
        return api.downloadBytes(resource.contentPath)
    }

    internal fun parseAsset(value: JSONObject): RemoteAsset {
        val resources = value.getJSONArray("resources")
        return RemoteAsset(
            id = value.getString("asset_id"),
            mediaKind = value.getString("media_kind"),
            createdAtMs = value.getLong("source_created_at_ms"),
            favorite = value.getBoolean("favorite"),
            archived = value.getBoolean("archived"),
            trashed = !value.isNull("trashed_at_ms"),
            tagNames = buildList {
                val tags = value.optJSONArray("tag_names") ?: org.json.JSONArray()
                for (position in 0 until tags.length()) add(tags.getString(position))
            },
            resources = buildList {
                for (position in 0 until resources.length()) {
                    val resource = resources.getJSONObject(position)
                    check(resource.getString("storage_encoding") == "plain-v1") {
                        "服务器返回了非当前存储协议"
                    }
                    add(
                        RemoteResource(
                            id = resource.getString("resource_id"),
                            role = resource.getString("role"),
                            filename = resource.getString("filename"),
                            mimeType = resource.getString("mime_type"),
                            contentPath = resource.getString("content_path"),
                            contentSize = resource.getLong("content_size"),
                            metadata = resource.optJSONObject("metadata"),
                        ),
                    )
                }
            },
        )
    }
}
