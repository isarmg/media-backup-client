package org.sarmg.xszc

import android.Manifest
import android.content.Context
import android.content.ContentUris
import android.content.pm.PackageManager
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal object LocalCatalog {
    const val PAGE_SIZE = 150
    data class Page(val rows: List<JSONObject>, val hasMore: Boolean)
    fun permissions() = if (Build.VERSION.SDK_INT >= 34) arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
        else if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    fun hasAccess(context: Context): Boolean = permissions().any {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }
    data class Scan(val albums: Map<String, String>, val sources: Set<String>)
    fun scan(context: Context, h: Long): Scan {
        check(permissions().any { ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED }) {
            "需要重新授权访问本地照片"
        }
        TransferStore.gallery(h, "begin_catalog")
        val albums = mutableMapOf<String, String>()
        val sources = mutableSetOf<String>()
        for ((collection, kind) in listOf(MediaStore.Images.Media.EXTERNAL_CONTENT_URI to "photo", MediaStore.Video.Media.EXTERNAL_CONTENT_URI to "video")) {
            val permission = if (Build.VERSION.SDK_INT >= 33) { if (kind == "photo") Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_MEDIA_VIDEO } else Manifest.permission.READ_EXTERNAL_STORAGE
            if (ContextCompat.checkSelfPermission(context, permission) != PackageManager.PERMISSION_GRANTED &&
                !(Build.VERSION.SDK_INT >= 34 && ContextCompat.checkSelfPermission(context, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED) == PackageManager.PERMISSION_GRANTED)) continue
            val columns = arrayOf("_id", "_display_name", "_size", "date_modified", "date_added", "datetaken", "bucket_id", "bucket_display_name")
            val cursor = context.contentResolver.query(collection, columns, null, null, null)
                ?: error("无法读取系统媒体库，请稍后重试")
            cursor.use { c ->
                var page = JSONArray()
                while (c.moveToNext()) {
                    val source = ContentUris.withAppendedId(collection, c.getLong(0)).toString()
                    sources += source
                    val name = c.getString(1) ?: "媒体"; val album = c.getString(6) ?: ""
                    albums[album] = c.getString(7) ?: "其他相册"
                    val modified = c.getLong(3) * 1000
                    val created = c.getLong(5).takeIf { it > 0 } ?: (c.getLong(4) * 1000)
                    val descriptor = JSONObject().put("uri", source).put("source_id", source).put("modified_ms", modified).put("name", name)
                    page.put(JSONObject().put("source_id", source).put("name", name).put("media_kind", kind).put("album_id", album)
                        .put("created_ms", created).put("modified_ms", modified).put("size", c.getLong(2).coerceAtLeast(0)).put("descriptor", descriptor.toString()))
                    if (page.length() == 200) { TransferStore.gallery(h, "catalog", JSONObject().put("items", page)); page = JSONArray() }
                }
                if (page.length() > 0) TransferStore.gallery(h, "catalog", JSONObject().put("items", page))
            }
        }
        TransferStore.gallery(h, "finish_catalog")
        return Scan(albums, sources)
    }
    fun page(h: Long, album: String?, kind: String?, unbacked: Boolean, offset: Int = 0, limit: Int = PAGE_SIZE): List<JSONObject> {
        val rows = TransferStore.gallery(h, "local_page", JSONObject().put("album", album ?: JSONObject.NULL).put("media_kind", kind ?: JSONObject.NULL)
            .put("unbacked", unbacked).put("offset", offset).put("limit", limit)) as JSONArray
        return (0 until rows.length()).map { rows.getJSONObject(it) }
    }
    fun window(h: Long, album: String?, kind: String?, unbacked: Boolean, offset: Int = 0, count: Int = PAGE_SIZE): Page {
        require(offset >= 0 && count > 0)
        val rows = mutableListOf<JSONObject>()
        while (rows.size < count) {
            val limit = minOf(PAGE_SIZE, count - rows.size)
            // Look ahead without consuming the first row of the following page.
            val fetched = page(h, album, kind, unbacked, offset + rows.size, limit + 1)
            rows += fetched.take(limit)
            if (fetched.size <= limit) return Page(rows, false)
        }
        return Page(rows, true)
    }
    fun persist(h: Long, selected: List<JSONObject>) {
        selected.chunked(1000).forEach { chunk ->
            TransferStore.command(h, "create_batch", JSONObject().put("id", UUID.randomUUID().toString()).put("items",
                JSONArray(chunk.map { JSONObject().put("id", UUID.randomUUID().toString()).put("source", it.getString("descriptor")) })))
        }
    }
    fun status(value: String): String = when(value) {
        "complete" -> "已备份"; "original_complete" -> "原件完成，缩略图待重试"; "queued" -> "排队中"
        "uploading" -> "上传中"; "failed" -> "备份失败"; else -> "状态待确认"
    }
}
