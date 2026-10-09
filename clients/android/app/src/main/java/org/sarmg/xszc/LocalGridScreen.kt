package org.sarmg.xszc

import android.database.ContentObserver
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.platform.testTag
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
import kotlinx.coroutines.Job
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.isActive
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONObject
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale

private data class LocalGalleryQuery(val profile: String, val album: String?, val kind: String?, val unbacked: Boolean)

@OptIn(ExperimentalFoundationApi::class)
@Composable
internal fun LocalGalleryScreen(context: Context, config: SecureConfig, profile: String, onSubmitted: () -> Unit, onLogin: () -> Unit) {
    val scope = rememberCoroutineScope()
    var rows by remember(profile) { mutableStateOf<List<JSONObject>>(emptyList()) }
    var selection by remember(profile) { mutableStateOf<Map<String, JSONObject>>(emptyMap()) }
    var selecting by remember(profile) { mutableStateOf(false) }
    val galleryPreferences = remember { context.getSharedPreferences("gallery_ui", Context.MODE_PRIVATE) }
    var gridColumns by rememberSaveable(profile) { mutableIntStateOf(galleryPreferences.getInt("columns", 3).coerceIn(1, 8)) }
    var albums by remember(profile) { mutableStateOf<Map<String, String>>(emptyMap()) }
    var album by remember(profile) { mutableStateOf<String?>(null) }
    var kind by remember(profile) { mutableStateOf<String?>(null) }
    var unbacked by remember(profile) { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    var notice by remember { mutableStateOf("") }
    var preview by remember { mutableStateOf<JSONObject?>(null) }
    var menu by remember { mutableStateOf(false) }
    var more by remember { mutableStateOf(false) }
    var loadingMore by remember { mutableStateOf(false) }
    var loadedQuery by remember(profile) { mutableStateOf<LocalGalleryQuery?>(null) }
    var loadedCapacity by remember(profile) { mutableIntStateOf(LocalCatalog.PAGE_SIZE) }
    var queuedRefresh by remember { mutableStateOf(false) }
    var queuedScan by remember { mutableStateOf(false) }
    val hasFilters = album != null || kind != null || unbacked
    val needsPairing = !config.isLoggedIn
    val dateFormat = remember { DateTimeFormatter.ofPattern("yyyy-MM-dd", Locale.getDefault()) }
    fun date(row: JSONObject) = Instant.ofEpochMilli(row.getLong("created_ms"))
        .atZone(ZoneId.systemDefault()).toLocalDate().format(dateFormat)
    fun load(scan: Boolean = false, append: Boolean = false) {
        if (busy) {
            if (!append) { queuedRefresh = true; queuedScan = queuedScan || scan }
            return
        }
        val query = LocalGalleryQuery(profile, album, kind, unbacked)
        val appending = append && loadedQuery == query
        val offset = if (appending) rows.size else 0
        val count = if (appending || loadedQuery != query) LocalCatalog.PAGE_SIZE else loadedCapacity
        busy = true
        loadingMore = appending
        scope.launch {
            try {
                val h = withContext(Dispatchers.IO) { TransferStore.open(context, profile).handle }
                if (!LocalCatalog.hasAccess(context)) {
                    rows = emptyList(); albums = emptyMap(); selection = emptyMap(); more = false; notice = ""
                    loadedQuery = null; loadedCapacity = LocalCatalog.PAGE_SIZE
                    return@launch
                }
                if (scan) {
                    val catalog = withContext(Dispatchers.IO) { LocalCatalog.scan(context, h) }
                    albums = catalog.albums
                    selection = selection.filterKeys { it in catalog.sources }
                }
                val page = withContext(Dispatchers.IO) { LocalCatalog.window(h, query.album, query.kind, query.unbacked, offset, count) }
                if (query != LocalGalleryQuery(profile, album, kind, unbacked)) {
                    queuedRefresh = true
                    return@launch
                }
                rows = if (appending) rows + page.rows else page.rows
                loadedCapacity = if (appending) loadedCapacity + LocalCatalog.PAGE_SIZE else count
                loadedQuery = query; more = page.hasMore; notice = ""
            } catch (e: CancellationException) { throw e
            } catch (e: Exception) { notice = e.message ?: "图库读取失败" } finally {
                busy = false
                loadingMore = false
                if (queuedRefresh && isActive) {
                    val pendingScan = queuedScan
                    queuedRefresh = false; queuedScan = false
                    load(scan = pendingScan)
                }
            }
        }
    }
    fun selectScope(day: String? = null) { if (!busy && LocalCatalog.hasAccess(context)) scope.launch {
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
        } catch (e: Exception) { notice = e.message ?: "选择失败" } finally {
            busy = false
            if (queuedRefresh) {
                val pendingScan = queuedScan
                queuedRefresh = false; queuedScan = false
                load(scan = pendingScan)
            }
        }
    } }
    fun toggle(row: JSONObject) { val id = row.getString("source_id"); selection = if (id in selection) selection - id else selection + (id to row) }
    fun submitBackup() {
        if (needsPairing) { onLogin(); return }
        if (selection.isEmpty()) { selecting = true; return }
        val selectedRows = selection.values.toList()
        busy = true
        scope.launch {
            try {
                withContext(Dispatchers.IO) { LocalCatalog.persist(TransferStore.open(context, profile).handle, selectedRows) }
                BackupScheduler.enqueueNow(context, config)
                selection = emptyMap(); selecting = false; onSubmitted()
            } catch (e: Exception) { notice = e.message ?: "提交失败" }
            finally {
                busy = false
                if (queuedRefresh) {
                    val pendingScan = queuedScan
                    queuedRefresh = false; queuedScan = false; load(scan = pendingScan)
                }
            }
        }
    }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { load(scan = true) }
    val refresh by rememberUpdatedState(newValue = { load(scan = true) })
    val lifecycle = LocalLifecycleOwner.current.lifecycle
    DisposableEffect(lifecycle, profile) {
        val observer = LifecycleEventObserver { _, event -> if (event == Lifecycle.Event.ON_RESUME) refresh() }
        lifecycle.addObserver(observer)
        var refreshJob: Job? = null
        val mediaObserver = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                refreshJob?.cancel()
                refreshJob = scope.launch { delay(300); refresh() }
            }
        }
        context.contentResolver.registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, true, mediaObserver)
        context.contentResolver.registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, true, mediaObserver)
        onDispose {
            lifecycle.removeObserver(observer)
            context.contentResolver.unregisterContentObserver(mediaObserver)
            refreshJob?.cancel()
        }
    }
    LaunchedEffect(profile) {
        val permissionsState = context.getSharedPreferences("photo_access_ui", Context.MODE_PRIVATE)
        if (!LocalCatalog.hasAccess(context) && !permissionsState.getBoolean("requested", false)) {
            permissionsState.edit().putBoolean("requested", true).apply()
            permission.launch(LocalCatalog.permissions())
        } else load(scan = true)
    }
    Box(Modifier.fillMaxSize()) {
        LazyVerticalGrid(GridCells.Fixed(gridColumns), Modifier.fillMaxSize().testTag("gallery.grid").galleryGridPinch(gridColumns) { columns ->
                if (columns != gridColumns) { gridColumns = columns; galleryPreferences.edit().putInt("columns", columns).apply() }
            },
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 64.dp, bottom = 12.dp),
            horizontalArrangement = Arrangement.spacedBy(3.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            item(span = { GridItemSpan(maxLineSpan) }) {
                Row(Modifier.fillMaxWidth().padding(bottom = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("已载入 ${rows.size} 项", Modifier.testTag("gallery.loaded-count"), style = MaterialTheme.typography.titleSmall)
                    if (selecting) Text("已选 ${selection.size} 项", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Spacer(Modifier.weight(1f))
                    if (hasFilters) GalleryInlineButton("清除筛选", onClick = { album = null; kind = null; unbacked = false; load() })
                }
            }
            if (notice.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }) {
                Text(notice, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }
            if (rows.isEmpty() && !busy) item(span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    GalleryEmptyState(if (hasFilters) "没有符合条件的照片" else "这里还没有照片",
                        if (hasFilters) "清除筛选后查看全部可访问的媒体。" else "允许访问选定照片或全部照片后，在这里浏览和备份。", R.drawable.ic_photo_library)
                    if (!hasFilters) Text("请在“设置 → 照片权限设置”中授权访问照片。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (hasFilters) TextButton(shape = AppShapes.control, onClick = { album = null; kind = null; unbacked = false; load() }) { Text("清除筛选") }
                }
            }
            rows.groupBy(::date).forEach { (day, group) ->
                item(key = "day-$day", span = { GridItemSpan(maxLineSpan) }) { Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
                    Text(day, Modifier.testTag("gallery.date.$day"), style = MaterialTheme.typography.titleSmall)
                    if (selecting) GalleryInlineButton("全选", enabled = !busy, onClick = { selectScope(day) })
                } }
                items(group, key = { it.getString("source_id") }) { row ->
                    val checked = row.getString("source_id") in selection
                    val status = row.getString("backup_state")
                    val badge = when (status) { "complete" -> "✓"; "queued", "uploading" -> "↑"; "failed", "original_complete" -> "!"; else -> null }
                    Box(Modifier.fillMaxWidth().testTag("gallery.photo.${row.getString("source_id")}").aspectRatio(1f).clip(RoundedCornerShape(8.dp))
                        .border(if (checked) 2.dp else 0.dp, if (checked) MaterialTheme.colorScheme.primary else Color.Transparent, RoundedCornerShape(8.dp))
                        .combinedClickable(onClick = { if (selecting) toggle(row) else preview = row }, onLongClick = {
                            selecting = true
                            if (!checked) toggle(row)
                        })
                        .semantics { contentDescription = "${if (row.getString("media_kind") == "video") "视频" else "照片"}，${row.getString("name")}" }) {
                        LocalImage(context, row, false, Modifier.fillMaxSize())
                        if (row.getString("media_kind") == "video") Text("▶", Modifier.align(Alignment.BottomStart).padding(5.dp)
                            .background(Color.Black.copy(alpha = 0.6f), CircleShape).padding(horizontal = 7.dp, vertical = 3.dp),
                            color = Color.White, style = MaterialTheme.typography.labelSmall)
                        if (badge != null) Text(badge, Modifier.align(Alignment.BottomEnd).padding(5.dp)
                            .background(Color.Black.copy(alpha = 0.6f), CircleShape).padding(horizontal = 7.dp, vertical = 3.dp)
                            .semantics { contentDescription = LocalCatalog.status(status) }, color = Color.White, style = MaterialTheme.typography.labelSmall)
                        if (row.getBoolean("excluded")) Text("⊘", Modifier.align(Alignment.TopStart).padding(5.dp)
                            .background(Color.Black.copy(alpha = 0.6f), CircleShape).padding(horizontal = 7.dp, vertical = 3.dp)
                            .semantics { contentDescription = "自动备份已排除" }, color = Color.White, style = MaterialTheme.typography.labelSmall)
                        if (selecting) GallerySelectionButton(checked, { toggle(row) }, Modifier.align(Alignment.TopEnd)
                            .semantics { contentDescription = "选择 ${row.getString("name")}" }, size = if (gridColumns >= 6) 24.dp else 44.dp)
                    }
                }
            }
            if (more) item(span = { GridItemSpan(maxLineSpan) }) {
                if (loadingMore) {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(Modifier.testTag("gallery.loading-more"))
                    }
                } else TextButton(shape = AppShapes.control, onClick = { load(append = true) }, enabled = !busy,
                    modifier = Modifier.testTag("gallery.load-more")) { Text("加载更多") }
            }
        }
        Row(Modifier.fillMaxWidth().align(Alignment.TopCenter).padding(horizontal = 16.dp, vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
            Box {
                GalleryToolbarButton("筛选", enabled = !busy, onClick = { menu = true }, modifier = Modifier.testTag("gallery.filter"))
                DropdownMenu(menu, { menu = false }) {
                    DropdownMenuItem(text = { Text("全部相册") }, onClick = { album = null; menu = false; load() })
                    albums.forEach { (id, name) -> DropdownMenuItem(text = { Text(name) }, onClick = { album = id; menu = false; load() }) }
                    HorizontalDivider()
                    listOf(null to "照片和视频", "photo" to "仅照片", "video" to "仅视频").forEach { (value, title) ->
                        DropdownMenuItem(text = { Text(title) }, trailingIcon = { if (kind == value) Text("✓") },
                            onClick = { kind = value; menu = false; load() })
                    }
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("仅未备份 / 待确认") }, trailingIcon = { if (unbacked) Text("✓") },
                        onClick = { unbacked = !unbacked; menu = false; load() })
                }
            }
            Spacer(Modifier.weight(1f))
            GalleryToolbarButton("备份", onClick = ::submitBackup, enabled = !busy, modifier = Modifier.testTag("gallery.backup"))
            if (selecting) {
                GalleryToolbarButton("全选", onClick = { selectScope() }, enabled = !busy, modifier = Modifier.testTag("gallery.select-all"))
                GalleryToolbarButton("取消", onClick = { selection = emptyMap(); selecting = false }, modifier = Modifier.testTag("gallery.cancel"))
            } else GalleryToolbarButton("选择", onClick = { selecting = true }, modifier = Modifier.testTag("gallery.select"))
        }
        if (busy && !loadingMore) LinearProgressIndicator(Modifier.fillMaxWidth().align(Alignment.TopCenter)
            .padding(start = 16.dp, end = 16.dp, top = 56.dp).testTag("gallery.loading"))
    }

    preview?.let { row ->
        if (row.getString("media_kind") == "video") Dialog(onDismissRequest = { preview = null }) {
            Surface { Column(Modifier.padding(12.dp)) {
                Text(row.getString("name"))
                LocalVideo(Uri.parse(row.getString("source_id")), Modifier.fillMaxWidth().height(300.dp))
                Text(LocalCatalog.status(row.getString("backup_state")))
                TextButton(shape = AppShapes.control, onClick = { selecting = true; toggle(row); preview = null }) { Text(if (row.getString("source_id") in selection) "取消选择" else "选择备份") }
                TextButton(shape = AppShapes.control, onClick = { scope.launch {
                    try {
                        withContext(Dispatchers.IO) { TransferStore.gallery(TransferStore.open(context, profile).handle, "exclude", JSONObject()
                            .put("source_id", row.getString("source_id")).put("excluded", !row.getBoolean("excluded"))) }
                        preview = null; load()
                    } catch (e: Exception) { notice = e.message ?: "操作失败" }
                } }) { Text(if (row.getBoolean("excluded")) "恢复自动备份" else "不再自动备份此项目") }
            } }
        } else {
            var previewMenu by remember(row.getString("source_id")) { mutableStateOf(false) }
            FullScreenPhotoDialog(onClose = { preview = null }) {
                Box(Modifier.fillMaxSize()) {
                    ZoomablePhotoFrame(onTap = { preview = null }, onLongPress = { previewMenu = true }) { imageModifier ->
                        LocalImage(context, row, true, imageModifier)
                    }
                    DropdownMenu(expanded = previewMenu, onDismissRequest = { previewMenu = false }) {
                        DropdownMenuItem(text = { Text(if (row.getString("source_id") in selection) "取消选择" else "选择备份") }, onClick = {
                            previewMenu = false; selecting = true; toggle(row); preview = null
                        })
                        DropdownMenuItem(text = { Text(if (row.getBoolean("excluded")) "恢复自动备份" else "不再自动备份此项目") }, onClick = {
                            previewMenu = false
                            scope.launch {
                                try {
                                    withContext(Dispatchers.IO) { TransferStore.gallery(TransferStore.open(context, profile).handle, "exclude", JSONObject()
                                        .put("source_id", row.getString("source_id")).put("excluded", !row.getBoolean("excluded"))) }
                                    preview = null; load()
                                } catch (e: Exception) { notice = e.message ?: "操作失败" }
                            }
                        })
                    }
                }
            }
        }
    }
}
private val localRequests = Semaphore(3)
@Composable
internal fun LocalImage(context: Context, row: JSONObject, preview: Boolean, modifier: Modifier, thumbnailSize: Int = 256) {
    var bitmap by remember(row.getString("source_id"), preview, thumbnailSize) { mutableStateOf<Bitmap?>(null) }
    LaunchedEffect(row.getString("source_id"), preview, thumbnailSize) {
        bitmap = withContext(Dispatchers.IO) { localRequests.withPermit { runCatching {
            val uri = Uri.parse(row.getString("source_id"))
            if (Build.VERSION.SDK_INT >= 29 && !preview) context.contentResolver.loadThumbnail(uri, Size(thumbnailSize, thumbnailSize), null)
            else {
                val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
                var sample = 1; val limit = if (preview) 2048 else thumbnailSize
                while (bounds.outWidth / sample > limit || bounds.outHeight / sample > limit) sample *= 2
                context.contentResolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample }) }
            }
        }.getOrNull() } }
    }
    Box(modifier) { bitmap?.let { Image(it.asImageBitmap(), row.getString("name"), Modifier.fillMaxSize(), contentScale = if (preview) ContentScale.Fit else ContentScale.Crop) }
        if (bitmap == null && !preview) Text("预览待加载") }
}
