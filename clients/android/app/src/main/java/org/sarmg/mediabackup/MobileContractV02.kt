package org.sarmg.mediabackup

import org.json.JSONObject

object MobileContractV02 {
    const val PRODUCT = "media-backup"
    const val APPLICATION_VERSION = "0.4.0"
    const val REVISION = 1
    const val STATE_EPOCH = "media-backup-mobile-v0.4-r1"

    const val DATABASE_FILENAME = "client-v0.4-r1.sqlite"
    const val STAGING_DIRECTORY = "backup-staging-v0.4-r1"
    const val PREFERENCES_FILE = "media_backup_secure_v0_2_r2"
    const val TOKEN_KEY = "bearer_token_v0_4_r1"
    const val WORK_TAG = "media-backup-v0.4-r1"
    const val NOW_WORK = "media-backup-now-v0.4-r1"
    const val PERIODIC_WORK = "media-backup-periodic-v0.4-r1"
    const val NOTIFICATION_CHANNEL = "media-backup-v0.4-r1"

    fun putIdentity(target: JSONObject): JSONObject = target
        .put("product", PRODUCT)
        .put("application_version", APPLICATION_VERSION)
        .put("revision", REVISION)
        .put("state_epoch", STATE_EPOCH)

    fun requireEnvelope(raw: String): JSONObject {
        val envelope = JSONObject(raw)
        val allowed = setOf(
            "product",
            "application_version",
            "revision",
            "state_epoch",
            "ok",
            "value",
            "error",
        )
        val keys = mutableSetOf<String>()
        val iterator = envelope.keys()
        while (iterator.hasNext()) keys += iterator.next()
        require(keys == allowed) { "Rust Client returned an unknown v0.2 envelope shape" }
        require(envelope.getString("product") == PRODUCT) { "Rust Client product mismatch" }
        require(envelope.getString("application_version") == APPLICATION_VERSION) {
            "Rust Client application version mismatch"
        }
        require(envelope.getInt("revision") == REVISION) { "Rust Client revision mismatch" }
        require(envelope.getString("state_epoch") == STATE_EPOCH) { "Rust Client state epoch mismatch" }
        if (!envelope.getBoolean("ok")) {
            error(envelope.optString("error", "Rust Client v0.2 operation failed"))
        }
        return envelope
    }

    fun requireIdentity(value: JSONObject) {
        require(value.getString("product") == PRODUCT) { "Rust Client job product mismatch" }
        require(value.getString("application_version") == APPLICATION_VERSION) {
            "Rust Client job application version mismatch"
        }
        require(value.getInt("revision") == REVISION) { "Rust Client job revision mismatch" }
        require(value.getString("state_epoch") == STATE_EPOCH) { "Rust Client job state epoch mismatch" }
    }
}
