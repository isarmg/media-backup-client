package org.sarmg.mediabackup

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.util.Size
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun LocalGalleryScreen(context: Context, config: SecureConfig, profile: String, onSubmitted: () -> Unit) {
    val scope = rememberCoroutineScope()
    var rows by remember(profile) { mutableStateOf<List<JSONObject>>(emptyList()) }
    var selection by remember(profile) { mutableStateOf<Map<String, JSONObject>>(emptyMap()) }
    var albums by remember(profile) { mutableStateOf<Map<String, String>>(emptyMap()) }
    var album by remember(profile) { mutableStateOf<String?>(null) }
    var kind by remember(profile) { mutableStateOf<String?>(null) }
    var unbacked by remember(profile) { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf("") }
    var access by remember { mutableStateOf(LocalCatalog.access(context)) }
    var systemPicker by remember { mutableStateOf(false) }
    var preview by remember { mutableStateOf<JSONObject?>(null) }
    var menu by remember { mutableStateOf(false) }
    var more by remember { mutableStateOf(false) }
    val dateFormat = remember { SimpleDateFormat("yyyy-MM-dd", Locale.getDefault()) }
    fun date(row: JSONObject) = dateFormat.format(Date(row.getLong("created_ms")))
    fun load(scan: Boolean = false, append: Boolean = false) {
        if (busy) return
        busy = true
        scope.launch {
            try {
                val h = withContext(Dispatchers.IO) { TransferStore.open(context, profile).handle }
                if (scan) { access = LocalCatalog.access(context); albums = withContext(Dispatchers.IO) { LocalCatalog.scan(context, h) }; selection = emptyMap() }
                val offset = if (append) rows.size else 0
                val page = withContext(Dispatchers.IO) { LocalCatalog.page(h, album, kind, unbacked, offset) }
                rows = if (append) rows + page else page; more = page.size == 150
            } catch (e: Exception) { notice = e.message ?: "图库读取失败" } finally { busy = false }
        }
    }
    fun selectScope(day: String? = null) { if (!busy) scope.launch {
        busy = true
        try {
            val chosen = withContext(Dispatchers.IO) {
                val h = TransferStore.open(context, profile).handle
                buildList { var offset = 0; do {
                    val page = LocalCatalog.page(h, album, kind, unbacked, offset, 1000)
                    addAll(page.filter { day == null || date(it) == day }); offset += page.size
                } while (page.size == 1000) }
            }
            selection = selection + chosen.associateBy { it.getString("source_id") }
        } catch (e: Exception) { notice = e.message ?: "选择失败" } finally { busy = false }
    } }
    fun toggle(row: JSONObject) { val id = row.getString("source_id"); selection = if (id in selection) selection - id else selection + (id to row) }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { load(scan = true) }
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, profile) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) load(scan = true) }
        lifecycle.addObserver(observer); onDispose { lifecycle.removeObserver(observer) }
    }
    LaunchedEffect(profile) { load(scan = true) }
    Column(Modifier.fillMaxSize()) {
        Text(access, style = MaterialTheme.typography.bodySmall)
        Row { TextButton(onClick = { permission.launch(LocalCatalog.permissions()) }) { Text("授权 / 调整范围") }
            TextButton(onClick = { systemPicker = true }) { Text("系统选择器") }; TextButton(onClick = { load(true) }) { Text("刷新") } }
        Row {
            Box { TextButton(enabled = !busy, onClick = { menu = true }) { Text(albums[album] ?: "全部相册") }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(text = { Text("全部相册") }, onClick = { album = null; menu = false; load() })
                    albums.forEach { (id, name) -> DropdownMenuItem(text = { Text(name) }, onClick = { album = id; menu = false; load() }) }
                } }
            TextButton(enabled = !busy, onClick = { kind = when(kind) { null -> "photo"; "photo" -> "video"; else -> null }; load() }) { Text(when(kind) { "photo" -> "照片"; "video" -> "视频"; else -> "全部类型" }) }
            TextButton(enabled = !busy, onClick = { unbacked = !unbacked; load() }) { Text(if (unbacked) "未备份 / 待确认" else "全部状态") }
        }
        Row { TextButton(onClick = { selectScope() }, enabled = !busy) { Text("选择当前筛选全部项目") }; TextButton(onClick = { selection = emptyMap() }) { Text("清空") } }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyVerticalGrid(GridCells.Adaptive(105.dp), Modifier.weight(1f)) {
            rows.groupBy(::date).forEach { (day, group) ->
                item(key = "day-$day", span = { GridItemSpan(maxLineSpan) }) { TextButton(onClick = { selectScope(day) }) { Text("$day · 选择此日期全部项目") } }
                items(group, key = { it.getString("source_id") }) { row ->
                    Column(Modifier.padding(3.dp).combinedClickable(onClick = { preview = row }, onLongClick = { toggle(row) })) {
                        LocalImage(context, row, false, Modifier.fillMaxWidth().aspectRatio(1f))
                        Row { Checkbox(row.getString("source_id") in selection, { toggle(row) }); Text(if (row.getString("media_kind") == "video") "视频" else "照片") }
                        Text(LocalCatalog.status(row.getString("backup_state")), style = MaterialTheme.typography.labelSmall)
                        if (row.getBoolean("excluded")) Text("自动备份已排除", style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
            if (more) item(span = { GridItemSpan(maxLineSpan) }) { TextButton(onClick = { load(append = true) }, enabled = !busy) { Text("加载更多") } }
        }
        Text("已选 ${selection.values.count { it.getString("media_kind") == "photo" }} 张照片、${selection.values.count { it.getString("media_kind") == "video" }} 个视频 · ${selection.values.sumOf { it.getLong("size") } / 1048576} MiB")
        Text(notice, style = MaterialTheme.typography.bodySmall)
        Button(enabled = selection.isNotEmpty() && !busy, onClick = { scope.launch {
            busy = true
            try {
                check(config.serverUrl.isNotBlank() && config.username.isNotBlank()) { "请先保存备份账户" }
                withContext(Dispatchers.IO) { LocalCatalog.persist(TransferStore.open(context, profile).handle, selection.values.toList()) }
                BackupScheduler.enqueueNow(context, config); selection = emptyMap(); onSubmitted()
            } catch (e: Exception) { notice = e.message ?: "提交失败" } finally { busy = false }
        } }) { Text("备份所选 ${selection.size} 项") }
    }
    if (systemPicker) Dialog(onDismissRequest = { systemPicker = false }, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) { Column(Modifier.padding(16.dp)) {
            TextButton(onClick = { systemPicker = false }) { Text("返回本地图库") }
            SystemSelectionScreen(context, config, profile) { systemPicker = false; onSubmitted() }
        } }
    }
    preview?.let { row -> Dialog(onDismissRequest = { preview = null }) { Surface { Column(Modifier.padding(12.dp)) {
        Text(row.getString("name"))
        if (row.getString("media_kind") == "video") LocalVideo(Uri.parse(row.getString("source_id")), Modifier.fillMaxWidth().height(300.dp))
        else LocalImage(context, row, true, Modifier.fillMaxWidth().height(300.dp))
        Text(LocalCatalog.status(row.getString("backup_state")))
        TextButton(onClick = { toggle(row); preview = null }) { Text(if (row.getString("source_id") in selection) "取消选择" else "选择备份") }
        TextButton(onClick = { scope.launch {
            withContext(Dispatchers.IO) { TransferStore.gallery(TransferStore.open(context, profile).handle, "exclude", JSONObject()
                .put("source_id", row.getString("source_id")).put("excluded", !row.getBoolean("excluded"))) }
            preview = null; load()
        } }) { Text(if (row.getBoolean("excluded")) "恢复自动备份" else "不再自动备份此项目") }
    } } } }
}
private val localRequests = Semaphore(3)
@Composable
private fun LocalImage(context: Context, row: JSONObject, preview: Boolean, modifier: Modifier) {
    var bitmap by remember(row.getString("source_id"), preview) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(row.getString("source_id"), preview) {
        bitmap = withContext(Dispatchers.IO) { localRequests.withPermit { runCatching {
            val uri = Uri.parse(row.getString("source_id"))
            if (Build.VERSION.SDK_INT >= 29 && !preview) context.contentResolver.loadThumbnail(uri, Size(256,256), null)
            else {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                var sample = 1; val limit = if (preview) 2048 else 256
                while (bounds.outWidth / sample > limit || bounds.outHeight / sample > limit) sample *= 2
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
            }
        }.getOrNull() } }
    }
    Box(modifier) { bitmap?.let { Image(it.asImageBitmap(), row.getString("name"), Modifier.fillMaxSize(), contentScale = if (preview) ContentScale.Fit else ContentScale.Crop) } ?: Text("预览待加载") }
}
