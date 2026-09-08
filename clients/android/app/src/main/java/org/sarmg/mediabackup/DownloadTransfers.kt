package org.sarmg.mediabackup

import kotlinx.coroutines.flow.MutableStateFlow
import java.util.UUID

/** Active-session download observations; interrupted saves clean their pending MediaStore row. */
internal object DownloadTransfers {
    data class Entry(val id: String, val profile: String, val name: String, val bytes: Long, val total: Long, val phase: String)
    val rows = MutableStateFlow<List<Entry>>(emptyList())
    @Synchronized fun start(profile: String, name: String, total: Long): String {
        val id = UUID.randomUUID().toString()
        rows.value = (listOf(Entry(id, profile, name, 0, total, "正在下载")) + rows.value).take(30)
        return id
    }
    @Synchronized fun update(id: String, bytes: Long? = null, phase: String? = null) {
        rows.value = rows.value.map { if (it.id == id) it.copy(bytes = bytes ?: it.bytes, phase = phase ?: it.phase) else it }
    }
}
