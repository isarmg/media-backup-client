package org.sarmg.mediabackup

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private data class Selection(val uri: Uri, val name: String, val video: Boolean, val bytes: Long?)

@Composable
internal fun SystemSelectionScreen(context: Context, config: SecureConfig, profile: String, onSubmitted: () -> Unit) {
    val scope = rememberCoroutineScope()
    var selection by remember(profile) { mutableStateOf<List<Selection>>(emptyList()) }
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf("") }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickMultipleVisualMedia(1000)) { uris ->
        scope.launch {
            busy = true
            try {
                val values = withContext(Dispatchers.IO) { uris.distinct().map { uri ->
                    var name = "媒体"
                    var bytes: Long? = null
                    context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use {
                        if (it.moveToFirst()) { name = it.getString(0) ?: name; if (!it.isNull(1)) bytes = it.getLong(1) }
                    }
                    Selection(uri, name, context.contentResolver.getType(uri)?.startsWith("video/") == true, bytes)
                } }
                if (config.profile == profile) selection = values
            } catch (e: Exception) { notice = e.message ?: "读取选择失败" }
            finally { busy = false }
        }
    }
    Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("选择要备份的媒体", style = MaterialTheme.typography.headlineMedium)
        Text("通过系统照片网格预览并选择照片和视频。仅上传确认的项目，未选择的内容不会加入本次批次。")
        Button(enabled = !busy, onClick = { picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageAndVideo)) }) { Text("打开照片选择器") }
        LazyColumn(Modifier.weight(1f)) {
            items(selection, key = { it.uri.toString() }) { item ->
                Row { Text(item.name, Modifier.weight(1f)); TextButton(onClick = { selection = selection - item }) { Text("移除") } }
            }
        }
        Text("已选择 ${selection.count { !it.video }} 张照片、${selection.count { it.video }} 个视频")
        Text("预计大小：${selection.sumOf { it.bytes ?: 0 } / (1024 * 1024)} MiB${if (selection.any { it.bytes == null }) " + 待确认大小" else ""}")
        Text(notice)
        Button(enabled = !busy && selection.isNotEmpty(), onClick = {
            if (config.serverUrl.isBlank() || config.authorizationCode.isBlank()) {
                notice = "请先在设置中保存服务器和备份账户"
            } else scope.launch {
                busy = true
                try {
                    withContext(Dispatchers.IO) { SelectedMedia.persist(context, profile, selection.map { it.uri }) }
                    if (config.profile == profile) { BackupScheduler.enqueueNow(context, config); selection = emptyList(); onSubmitted() }
                } catch (e: Exception) { notice = "提交失败：${e.message}" }
                finally { busy = false }
            }
        }) { Text("备份所选 ${selection.size} 项") }
    }
}
