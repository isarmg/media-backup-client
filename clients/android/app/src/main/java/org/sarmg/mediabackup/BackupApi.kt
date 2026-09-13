package org.sarmg.mediabackup

import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.asRequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.io.OutputStream
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine

class BackupApi(
    private val serverUrl: String,
    private var bearerToken: String,
    client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(30, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.MINUTES)
        .writeTimeout(10, TimeUnit.MINUTES)
        .build(),
) {
    private val client = client.newBuilder().followRedirects(false).followSslRedirects(false).build()
    private val origin = serverUrl.toHttpUrl()
    init {
        require(origin.isHttps && origin.username.isEmpty() && origin.password.isEmpty() && origin.encodedPath == "/" && origin.query == null && origin.fragment == null) { "服务器地址必须使用 HTTPS" }
    }
    var accountId: String = ""; private set
    var deviceId: String = ""; private set
    private val jsonType = "application/json".toMediaType()
    private val binaryType = "application/octet-stream".toMediaType()

    fun health(): Boolean {
        val request = Request.Builder().url("${serverUrl.trimEnd('/')}/healthz").get().build()
        client.newCall(request).execute().use {
            if (it.code != 204) error("服务端健康检查失败: ${it.code}")
            return true
        }
    }

    fun bootstrap(authorizationCode: String, deviceName: String): String {
        val body = JSONObject()
            .put("authorization_code", authorizationCode)
            .put("device_name", deviceName)
            .put("platform", "android")
            .toString()
            .toRequestBody(jsonType)
        val request = Request.Builder().url("$serverUrl/v2/auth/bootstrap").post(body).build()
        val response = client.newCall(request).execute()
        response.use {
            val text = it.body.string()
            if (it.code == 401 || it.code == 403) error("授权码无效、已取消或已被配对")
            if (!it.isSuccessful) error("配对失败（HTTP ${it.code}），请稍后重试")
            val result = JSONObject(text)
            accountId = result.getString("account_id"); deviceId = result.getString("device_id")
            bearerToken = result.getString("bearer_token")
            return bearerToken
        }
    }

    fun createUpload(requestJson: String): JSONObject = jsonRequest("$serverUrl/v2/uploads", "POST", requestJson)

    fun uploadPart(uploadId: String, index: Int, file: File) {
        val request = authenticated(Request.Builder().url("$serverUrl/v2/uploads/$uploadId/parts/$index"))
            .put(file.asRequestBody(binaryType))
            .build()
        client.newCall(request).execute().use {
            if (!it.isSuccessful) error("分块上传失败: ${it.code} ${it.body.string()}")
        }
    }

    fun complete(uploadId: String): JSONObject =
        jsonRequest("$serverUrl/v2/uploads/$uploadId/complete", "POST", "{}")

    fun syncAlbum(
        sourceAlbumId: String,
        name: String,
        sourceAssetIds: Set<String>,
        replaceMembers: Boolean,
    ): JSONObject {
        val assets = org.json.JSONArray()
        sourceAssetIds.forEach(assets::put)
        val body = JSONObject()
            .put("source_album_id", sourceAlbumId)
            .put("name", name)
            .put("source_asset_ids", assets)
            .put("replace_members", replaceMembers)
        return jsonRequest("$serverUrl/v2/albums", "POST", body.toString())
    }

    fun timeline(cursor: String? = null, trashed: Boolean = false, favorite: Boolean = false, albumId: String? = null, filters: CloudFilters = CloudFilters()): JSONObject {
        val suffix = buildString {
            append("?limit=100&trashed=").append(trashed)
            filters.params().forEach { (name, value) -> append("&").append(name).append("=").append(java.net.URLEncoder.encode(value, "UTF-8")) }
            if (favorite) append("&favorite=true")
            if (albumId != null) append("&album_id=").append(java.net.URLEncoder.encode(albumId, "UTF-8"))
            if (!cursor.isNullOrBlank()) append("&cursor=").append(java.net.URLEncoder.encode(cursor, "UTF-8"))
        }
        return jsonRequest("$serverUrl/v2/timeline$suffix", "GET", null)
    }

    internal fun get(path: String, allowMissing: Boolean = false): JSONObject? {
        client.newCall(authenticated(Request.Builder().url(resolve(path))).get().build()).execute().use {
            if (allowMissing && it.code == 404) return null
            check(it.isSuccessful) { "图库请求失败：${it.code}" }
            return JSONObject(it.body.string())
        }
    }
    internal fun devices() = jsonArrayRequest("$serverUrl/v2/devices")
    internal fun videoFactory(): androidx.media3.datasource.DataSource.Factory =
        androidx.media3.datasource.okhttp.OkHttpDataSource.Factory(client)
            .setDefaultRequestProperties(mapOf("Authorization" to "Bearer $bearerToken"))

    fun manifest(resourceId: String): JSONObject = jsonRequest("$serverUrl/v2/resources/$resourceId", "GET", null)

    fun sync(after: Long): JSONObject =
        jsonRequest("$serverUrl/v2/sync?after=$after&limit=1000", "GET", null)

    fun updateAsset(assetId: String, favorite: Boolean? = null, archived: Boolean? = null): JSONObject {
        val body = JSONObject()
        favorite?.let { body.put("favorite", it) }
        archived?.let { body.put("archived", it) }
        return jsonRequest("$serverUrl/v2/assets/$assetId", "PATCH", body.toString())
    }

    fun trashAsset(assetId: String) {
        jsonRequest("$serverUrl/v2/assets/$assetId/trash", "POST", "{}", expectJson = false)
    }

    fun restoreAsset(assetId: String) {
        jsonRequest("$serverUrl/v2/assets/$assetId/restore", "POST", "{}", expectJson = false)
    }

    fun duplicateGroups(): org.json.JSONArray =
        jsonArrayRequest("$serverUrl/v2/duplicates?limit=50")

    fun listAlbums(): org.json.JSONArray = jsonArrayRequest("$serverUrl/v2/albums")

    fun listTags(): org.json.JSONArray = jsonArrayRequest("$serverUrl/v2/tags")

    fun createTag(name: String): JSONObject = jsonRequest(
        "$serverUrl/v2/tags",
        "POST",
        JSONObject().put("name", name).toString(),
    )

    fun addTagAsset(tagId: String, assetId: String) {
        jsonRequest("$serverUrl/v2/tags/$tagId/assets/$assetId", "POST", "{}", expectJson = false)
    }

    fun download(path: String, output: OutputStream) {
        val request = authenticated(Request.Builder().url(resolve(path))).get().build()
        client.newCall(request).execute().use {
            if (!it.isSuccessful) error("下载失败: ${it.code} ${it.body.string()}")
            it.body.byteStream().use { input -> input.copyTo(output) }
        }
    }

    suspend fun downloadCancellable(path: String, output: OutputStream): Unit = suspendCancellableCoroutine { continuation ->
        val request = authenticated(Request.Builder().url(resolve(path))).get().build()
        val call = client.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : okhttp3.Callback {
            override fun onFailure(call: okhttp3.Call, error: java.io.IOException) {
                if (continuation.isActive) continuation.resumeWithException(error)
            }
            override fun onResponse(call: okhttp3.Call, response: okhttp3.Response) {
                try {
                    response.use {
                        check(it.isSuccessful) { "下载失败：${it.code}" }
                        it.body.byteStream().use { input -> input.copyTo(output) }
                    }
                    if (continuation.isActive) continuation.resume(Unit)
                } catch (error: Exception) {
                    if (continuation.isActive) continuation.resumeWithException(error)
                }
            }
        })
    }

    fun downloadBytes(path: String): ByteArray {
        val request = authenticated(Request.Builder().url(resolve(path))).get().build()
        client.newCall(request).execute().use {
            if (!it.isSuccessful) error("下载失败: ${it.code} ${it.body.string()}")
            return it.body.bytes()
        }
    }

    private fun jsonRequest(url: String, method: String, bodyText: String?, expectJson: Boolean = true): JSONObject {
        val builder = authenticated(Request.Builder().url(url))
        when (method) {
            "GET" -> builder.get()
            "POST" -> builder.post((bodyText ?: "{}").toRequestBody(jsonType))
            "PATCH" -> builder.patch((bodyText ?: "{}").toRequestBody(jsonType))
            else -> error("unsupported method")
        }
        client.newCall(builder.build()).execute().use {
            val text = it.body.string()
            if (!it.isSuccessful) error("服务端请求失败: ${it.code} $text")
            return if (expectJson && text.isNotBlank()) JSONObject(text) else JSONObject()
        }
    }

    private fun jsonArrayRequest(url: String): org.json.JSONArray {
        val request = authenticated(Request.Builder().url(url)).get().build()
        client.newCall(request).execute().use {
            val text = it.body.string()
            if (!it.isSuccessful) error("服务端请求失败: ${it.code} $text")
            return org.json.JSONArray(text)
        }
    }

    internal fun resolve(path: String): String {
        val url = origin.resolve(path) ?: error("资源地址无效")
        require(url.isHttps && url.host == origin.host && url.port == origin.port &&
            url.username.isEmpty() && url.password.isEmpty()) { "资源地址必须与服务器 HTTPS 同源" }
        return url.toString()
    }

    private fun authenticated(builder: Request.Builder): Request.Builder =
        builder.header("Authorization", "Bearer $bearerToken")
}
