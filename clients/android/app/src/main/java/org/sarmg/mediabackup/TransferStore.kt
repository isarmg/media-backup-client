package org.sarmg.mediabackup

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

internal fun profileKey(server: String, username: String): String = MessageDigest.getInstance("SHA-256")
    .digest("${server.trim().trimEnd('/')}\n${username.trim()}".toByteArray()).joinToString("") { "%02x".format(it) }

/** One native handle per account in this process; reopening must not reset a live upload. */
internal object TransferStore {
    data class Session(val handle: Long, val paths: NativeStorage.Paths)
    private val sessions = mutableMapOf<String, Session>()

    @Synchronized fun open(context: Context, profile: String): Session = sessions.getOrPut(profile) {
        val paths = NativeStorage.prepare(context, profile)
        val handle = NativeBridgeV2.open(paths.database.path,
            MobileContractV02.putIdentity(JSONObject()).put("part_size", 16 * 1024 * 1024).toString())
        check(handle != 0L) { "无法打开备份记录" }
        Session(handle, paths)
    }

    fun command(handle: Long, op: String, fields: JSONObject = JSONObject()): Any? {
        fields.put("op", op)
        return MobileContractV02.requireEnvelope(NativeBridgeV2.transfer(handle,
            MobileContractV02.putIdentity(JSONObject()).put("command", fields).toString())).opt("value")
    }
    fun gallery(handle: Long, op: String, fields: JSONObject = JSONObject()): Any? =
        command(handle, "gallery", JSONObject().put("command", fields.put("op", op)))
    fun batches(handle: Long) = command(handle, "batches") as JSONArray
    fun items(handle: Long, batch: String) = command(handle, "items", JSONObject().put("batch_id", batch)) as JSONArray
    fun setItem(handle: Long, batch: String, item: String, state: String, error: String? = null) {
        command(handle, "set_item", JSONObject().put("batch_id", batch).put("item_id", item)
            .put("state", state).put("error", error ?: JSONObject.NULL))
    }
    fun receipt(handle: Long, job: JSONObject, result: JSONObject) {
        command(handle, "receipt", JSONObject().put("job_id", job.getString("job_id"))
            .put("asset_id", result.getString("asset_id")).put("resource_id", result.getString("resource_id"))
            .put("content_blake3", job.getJSONObject("request").getString("content_blake3")))
        MobileContractV02.requireEnvelope(NativeBridgeV2.markComplete(handle, job.getString("job_id")))
    }
}
