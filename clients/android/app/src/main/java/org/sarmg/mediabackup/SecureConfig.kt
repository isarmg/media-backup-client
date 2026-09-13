package org.sarmg.mediabackup

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray

data class BackupSnapshot(
    val state: String = "idle",
    val message: String = "尚未开始备份",
    val lastRunAt: Long = 0L,
    val lastSuccessAt: Long = 0L,
    val discovered: Int = 0,
    val completed: Int = 0,
    val failed: Int = 0,
    val uploadedBytes: Long = 0L,
    val currentItem: String = "",
)

class SecureConfig(context: Context) {
    private val masterKey = MasterKey.Builder(context)
        .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
        .build()
    private val preferences = EncryptedSharedPreferences.create(
        context,
        MobileContractV02.PREFERENCES_FILE,
        masterKey,
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    companion object { private val connectionLock = Any() }
    data class Connection(val server: String, val authorizationCode: String, val token: String,
        val accountId: String, val deviceId: String, val profile: String = provisionalProfileKey(server, authorizationCode))
    val profile: String get() = synchronized(connectionLock) {
        preferences.getString("queue_profile_v04", null) ?: provisionalProfileKey(serverUrl, authorizationCode)
    }
    fun connection(): Connection = synchronized(connectionLock) { Connection(serverUrl, authorizationCode, bearerToken, accountId, deviceId, profile) }
    fun saveCredentials(server: String, code: String) = synchronized(connectionLock) {
        serverUrl = server; authorizationCode = code
    }

    fun saveAuthenticatedConnection(expected: Connection, server: String, code: String,
        api: BackupApi, token: String, storageProfile: String) = synchronized(connectionLock) {
        check(connection() == expected) { "配对信息已改变，请重新配对" }
        check(token.isNotBlank()) { "服务器没有返回有效配对凭据" }
        require(storageProfile.matches(Regex("[0-9a-f]{64}")))
        preferences.edit().putString("queue_profile_v04", storageProfile)
            .putString("server_url", server).putString("authorization_code", code)
            .putString("account_id_v04", api.accountId)
            .putString("device_id_v04", api.deviceId).putString(MobileContractV02.TOKEN_KEY, token).apply()
    }

    var serverUrl: String
        get() = preferences.getString("server_url", "") ?: ""
        set(value) {
            val normalized = value.trim().trimEnd('/')
            val editor = preferences.edit().putString("server_url", normalized)
            if (normalized != serverUrl) editor.remove(MobileContractV02.TOKEN_KEY).remove("queue_profile_v04")
            editor.apply()
        }

    var authorizationCode: String
        get() = preferences.getString("authorization_code", "") ?: ""
        set(value) {
            val normalized = value.trim()
            val editor = preferences.edit().putString("authorization_code", normalized)
            if (normalized != authorizationCode) editor.remove(MobileContractV02.TOKEN_KEY).remove("queue_profile_v04")
            editor.apply()
        }

    var bearerToken: String
        get() = preferences.getString(MobileContractV02.TOKEN_KEY, "") ?: ""
        set(value) = preferences.edit().putString(MobileContractV02.TOKEN_KEY, value).apply()

    var accountId: String
        get() = preferences.getString("account_id_v04", "") ?: ""
        set(value) = preferences.edit().putString("account_id_v04", value).apply()
    var deviceId: String
        get() = preferences.getString("device_id_v04", "") ?: ""
        set(value) = preferences.edit().putString("device_id_v04", value).apply()
    var autoBackup: Boolean
        get() = preferences.getBoolean("auto_backup", false)
        set(value) = preferences.edit().putBoolean("auto_backup", value).apply()

    var wifiOnly: Boolean
        get() = preferences.getBoolean("wifi_only", true)
        set(value) = preferences.edit().putBoolean("wifi_only", value).apply()

    var chargingOnly: Boolean
        get() = preferences.getBoolean("charging_only", false)
        set(value) = preferences.edit().putBoolean("charging_only", value).apply()

    var backupPhotos: Boolean
        get() = preferences.getBoolean("backup_medias", true)
        set(value) = preferences.edit().putBoolean("backup_medias", value).apply()

    var backupVideos: Boolean
        get() = preferences.getBoolean("backup_videos", true)
        set(value) = preferences.edit().putBoolean("backup_videos", value).apply()

    var cameraOnly: Boolean
        get() = preferences.getBoolean("camera_only", true)
        set(value) = preferences.edit().putBoolean("camera_only", value).apply()

    var selectedAlbumIds: Set<String>
        get() = runCatching {
            val array = JSONArray(preferences.getString("selected_album_ids", "[]"))
            buildSet { for (index in 0 until array.length()) add(array.getString(index)) }
        }.getOrDefault(emptySet())
        set(value) {
            val array = JSONArray()
            value.sorted().forEach(array::put)
            preferences.edit()
                .putString("selected_album_ids", array.toString())
                .putBoolean("album_selection_configured", true)
                .apply()
        }

    val albumSelectionConfigured: Boolean
        get() = preferences.getBoolean("album_selection_configured", false)

    var librarySyncSequence: Long
        get() = preferences.getLong("library_sync_sequence", 0L)
        set(value) = preferences.edit().putLong("library_sync_sequence", value).apply()

    fun snapshot(): BackupSnapshot = BackupSnapshot(
        state = preferences.getString("backup_state", "idle") ?: "idle",
        message = preferences.getString("backup_message", "尚未开始备份") ?: "尚未开始备份",
        lastRunAt = preferences.getLong("last_run_at", 0L),
        lastSuccessAt = preferences.getLong("last_success_at", 0L),
        discovered = preferences.getInt("last_discovered", 0),
        completed = preferences.getInt("last_completed", 0),
        failed = preferences.getInt("last_failed", 0),
        uploadedBytes = preferences.getLong("last_uploaded_bytes", 0L),
        currentItem = preferences.getString("current_item", "") ?: "",
    )

    fun saveSnapshot(snapshot: BackupSnapshot) {
        preferences.edit()
            .putString("backup_state", snapshot.state)
            .putString("backup_message", snapshot.message)
            .putLong("last_run_at", snapshot.lastRunAt)
            .putLong("last_success_at", snapshot.lastSuccessAt)
            .putInt("last_discovered", snapshot.discovered)
            .putInt("last_completed", snapshot.completed)
            .putInt("last_failed", snapshot.failed)
            .putLong("last_uploaded_bytes", snapshot.uploadedBytes)
            .putString("current_item", snapshot.currentItem)
            .apply()
    }

}
