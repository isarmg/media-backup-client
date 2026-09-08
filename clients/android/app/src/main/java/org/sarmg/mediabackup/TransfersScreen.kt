package org.sarmg.mediabackup

import android.content.Context
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

@Composable
internal fun TransfersScreen(context: Context, config: SecureConfig, profile: String) {
    val scope = rememberCoroutineScope()
    val downloads by DownloadTransfers.rows.collectAsState()
    var batches by remember { mutableStateOf<List<Pair<JSONObject, List<JSONObject>>>>(emptyList()) }
    var notice by remember { mutableStateOf("") }
    LaunchedEffect(profile) {
        while (true) {
            try {
                batches = withContext(Dispatchers.IO) {
                    val handle = TransferStore.open(context, profile).handle
                    val rows = TransferStore.batches(handle)
                    (0 until rows.length()).map { i ->
                        val batch = rows.getJSONObject(i)
                        val items = TransferStore.items(handle, batch.getString("id"))
                        batch to (0 until items.length()).map(items::getJSONObject)
                    }
                }
                notice = config.snapshot().message
            } catch (e: Exception) { notice = e.message ?: "读取任务失败" }
            delay(1500)
        }
    }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item {
            Text("传输", style = MaterialTheme.typography.headlineMedium)
            Text(notice)
            Text("等待 Wi-Fi、充电或系统调度时会保留批次。取消批次不会删除云端副本。", style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = { BackupScheduler.enqueueNow(context, config) }) { Text("继续待处理任务") }
        }
        item { Text("下载", style = MaterialTheme.typography.titleMedium) }
        downloads.filter { it.profile == profile }.forEach { download ->
            item(key = download.id) { Text("${download.name} · ${download.phase} · ${download.bytes / 1048576} / ${download.total / 1048576} MiB") }
        }
        item { Text("上传", style = MaterialTheme.typography.titleMedium) }
        for ((batch, items) in batches) {
            item(key = batch.getString("id")) {
                Card {
                    Column(Modifier.padding(12.dp)) {
                        Text("所选批次：${batch.getInt("complete")} / ${batch.getInt("items")} 项完成")
                        if (batch.getBoolean("cancelled")) Text("已取消本次上传")
                        for (item in items) {
                            val state = when {
                                item.getString("state") == "blocked" -> (if (item.getInt("originals_expected") > 0 && item.getInt("originals_complete") >= item.getInt("originals_expected")) "原件已备份，关联资源待重试：" else "") + item.optString("error", "需要重新授权")
                                item.getString("state") == "queued" && item.getInt("resources") > 0 && item.getInt("resources") == item.getInt("complete") -> "所选副本已备份"
                                !item.isNull("upload_error") && item.getInt("originals_expected") > 0 && item.getInt("originals_complete") >= item.getInt("originals_expected") -> "原件已备份，关联资源待重试"
                                !item.isNull("upload_error") -> "等待重试：${item.getString("upload_error") }"
                                item.getString("state") == "queued" -> "排队中 / 上传中"
                                else -> "等待准备原始文件"
                            }
                            Text("${JSONObject(item.getString("source")).optString("name", "媒体")} · $state", style = MaterialTheme.typography.bodySmall)
                        }
                        Row {
                            listOf("cancel_batch" to "取消本次上传", "retry_batch" to "重试批次").forEach { (op, title) ->
                                TextButton(onClick = { scope.launch {
                                    withContext(Dispatchers.IO) {
                                        TransferStore.command(TransferStore.open(context, profile).handle, op,
                                            JSONObject().put("batch_id", batch.getString("id")))
                                    }
                                    if (op == "retry_batch") BackupScheduler.enqueueNow(context, config)
                                } }) { Text(title) }
                            }
                        }
                    }
                }
            }
        }
    }
}
