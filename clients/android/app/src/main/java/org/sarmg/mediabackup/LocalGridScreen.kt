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
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
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
internal fun LocalGalleryScreen(context: Context, config: SecureConfig, profile: String, onSubmitted: () -> Unit, onLogin: () -> Unit) {
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
    var actions by remember { mutableStateOf(false) }
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
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            TextButton(onClick = { selectScope() }, enabled = !busy) { Text("全选筛选结果") }
            Box {
                FilledTonalButton(onClick = { actions = true }) { Text("添加照片") }
                DropdownMenu(actions, { actions = false }) {
                    DropdownMenuItem(text = { Text("从系统照片选择") }, onClick = { actions = false; systemPicker = true })
                    DropdownMenuItem(text = { Text("授权 / 调整照片范围") }, onClick = { actions = false; permission.launch(LocalCatalog.permissions()) })
                    DropdownMenuItem(text = { Text("刷新图库") }, onClick = { actions = false; load(true) })
                }
            }
        }
        Text(access, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Row(Modifier.horizontalScroll(rememberScrollState())) {
            Box { TextButton(enabled = !busy, onClick = { menu = true }) { Text(albums[album] ?: "全部相册") }
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(text = { Text("全部相册") }, onClick = { album = null; menu = false; load() })
                    albums.forEach { (id, name) -> DropdownMenuItem(text = { Text(name) }, onClick = { album = id; menu = false; load() }) }
                } }
            TextButton(enabled = !busy, onClick = { kind = when(kind) { null -> "photo"; "photo" -> "video"; else -> null }; load() }) { Text(when(kind) { "photo" -> "照片"; "video" -> "视频"; else -> "全部类型" }) }
            TextButton(enabled = !busy, onClick = { unbacked = !unbacked; load() }) { Text(if (unbacked) "未备份 / 待确认" else "全部状态") }
        }
        if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyVerticalGrid(GridCells.Adaptive(105.dp), Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (rows.isEmpty() && !busy) item(span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.fillMaxWidth().padding(vertical = 36.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                    Text("这里还没有照片", style = MaterialTheme.typography.titleMedium)
                    Text("添加可访问的照片，或调整筛选条件。", Modifier.padding(12.dp), style = MaterialTheme.typography.bodySmall)
                    Button(onClick = { systemPicker = true }) { Text("选择照片") }
                }
            }
            rows.groupBy(::date).forEach { (day, group) ->
                item(key = "day-$day", span = { GridItemSpan(maxLineSpan) }) { Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text(day, style = MaterialTheme.typography.titleSmall)
                    TextButton(enabled = !busy, onClick = { selectScope(day) }) { Text("全选") }
                } }
                items(group, key = { it.getString("source_id") }) { row ->
                    val checked = row.getString("source_id") in selection
                    Column {
                        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(10.dp))
                            .border(if (checked) 2.dp else 0.dp, if (checked) MaterialTheme.colorScheme.primary else Color.Transparent, RoundedCornerShape(10.dp))) {
                            LocalImage(context, row, false, Modifier.fillMaxSize()
                                .combinedClickable(onClick = { preview = row }, onLongClick = { toggle(row) }))
                            if (row.getString("media_kind") == "video") Text("视频", Modifier.align(Alignment.BottomStart).padding(6.dp)
                                .background(Color.Black.copy(alpha = 0.5f), RoundedCornerShape(6.dp)).padding(4.dp), color = Color.White, style = MaterialTheme.typography.labelSmall)
                            Checkbox(checked, { toggle(row) }, Modifier.align(Alignment.TopEnd).padding(2.dp)
                                .clip(CircleShape).background(Color.Black.copy(alpha = 0.3f))
                                .semantics { contentDescription = "选择 ${row.getString("name")}" },
                                colors = CheckboxDefaults.colors(uncheckedColor = Color.White, checkmarkColor = Color.White))
                        }
                        Text(LocalCatalog.status(row.getString("backup_state")), style = MaterialTheme.typography.labelSmall)
                        if (row.getBoolean("excluded")) Text("自动备份已排除", style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
            if (more) item(span = { GridItemSpan(maxLineSpan) }) { TextButton(onClick = { load(append = true) }, enabled = !busy) { Text("加载更多") } }
        }
        Surface(tonalElevation = 3.dp, shape = RoundedCornerShape(16.dp)) {
            Column(Modifier.fillMaxWidth().padding(12.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                if (selection.isNotEmpty()) Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text("已选 ${selection.size} 项", style = MaterialTheme.typography.titleSmall)
                    TextButton(onClick = { selection = emptyMap() }) { Text("清空选择") }
                }
                if (notice.isNotEmpty()) Text(notice, style = MaterialTheme.typography.bodySmall)
                Button(modifier = Modifier.fillMaxWidth(), enabled = !busy && (selection.isNotEmpty() || config.authorizationCode.isBlank()), onClick = {
                    if (config.serverUrl.isBlank() || config.authorizationCode.isBlank()) onLogin()
                    else scope.launch {
                        busy = true
                        try {
                            withContext(Dispatchers.IO) { LocalCatalog.persist(TransferStore.open(context, profile).handle, selection.values.toList()) }
                            BackupScheduler.enqueueNow(context, config); selection = emptyMap(); onSubmitted()
                        } catch (e: Exception) { notice = e.message ?: "提交失败" } finally { busy = false }
                    }
                }) { Text(if (config.authorizationCode.isBlank()) "配对后备份" else if (selection.isEmpty()) "勾选照片开始备份" else "备份所选 ${selection.size} 项") }
            }
        }
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
