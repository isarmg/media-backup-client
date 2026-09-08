package org.sarmg.mediabackup

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.security.MessageDigest

internal fun profileKey(server: String, username: String): String = MessageDigest.getInstance("SHA-256")
    .digest("${server.trim().trimEnd('/')}\n${username.trim()}".toByteArray()).joinToString("") { "%02x".format(it) }

internal fun accountProfileKey(server: String, accountId: String): String = MessageDigest.getInstance("SHA-256")
    .digest("media-backup-account-v1\n${server.trim().trimEnd('/')}\n${java.util.UUID.fromString(accountId)}".toByteArray())
    .joinToString("") { "%02x".format(it) }

/** One native handle per account in this process; reopening must not reset a live upload. */
internal object TransferStore {
    data class Session(val handle: Long, val paths: NativeStorage.Paths, val profile: String)
    private val sessions = mutableMapOf<String, Session>()

    @Synchronized fun open(context: Context, profile: String): Session = sessions.getOrPut(profile) {
        val paths = NativeStorage.prepare(context, profile)
        val handle = NativeBridgeV2.open(paths.database.path,
            MobileContractV02.putIdentity(JSONObject()).put("part_size", 16 * 1024 * 1024).toString())
        check(handle != 0L) { "无法打开备份记录" }
        Session(handle, paths, profile)
    }

    /** Reuse matching queues; a recreated account gets a separate queue without deleting the old one. */
    fun bindAccount(context: Context, server: String, username: String, accountId: String, deviceId: String): Session {
        val legacy = open(context, profileKey(server, username))
        val binding = command(legacy.handle, "binding") as? JSONObject
        val matches = binding == null || (binding.getString("server") == server &&
            java.util.UUID.fromString(binding.getString("account_id")) == java.util.UUID.fromString(accountId))
        val target = if (matches) legacy else open(context, accountProfileKey(server, accountId))
        command(target.handle, "bind", JSONObject().put("server", server)
            .put("account_id", accountId).put("device_id", deviceId))
        return target
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
