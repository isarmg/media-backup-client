package org.sarmg.mediabackup

import android.content.Context
import android.Manifest
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import android.graphics.Bitmap
import android.os.Build
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun CloudGalleryScreen(context: Context, config: SecureConfig, profile: String) {
    val scope = rememberCoroutineScope()
    var api by remember(profile) { mutableStateOf<BackupApi?>(null) }
    var assets by remember(profile) { mutableStateOf<List<RemoteAsset>>(emptyList()) }
    var cursor by remember(profile) { mutableStateOf<String?>(null) }
    var started by remember(profile) { mutableStateOf(false) }
    var loading by remember(profile) { mutableStateOf(false) }
    var notice by remember(profile) { mutableStateOf("") }
    var trash by remember(profile) { mutableStateOf(false) }
    var favorites by remember(profile) { mutableStateOf(false) }
    var albums by remember(profile) { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    var albumId by remember(profile) { mutableStateOf<String?>(null) }
    var showFilters by remember { mutableStateOf(false) }
    var albumMenu by remember(profile) { mutableStateOf(false) }
    var filters by remember(profile) { mutableStateOf(CloudFilters()) }
    var devices by remember(profile) { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    var deviceMenu by remember { mutableStateOf(false) }
    var fromDate by remember { mutableStateOf("") }
    var toDate by remember { mutableStateOf("") }
    var generation by remember(profile) { mutableIntStateOf(0) }
    var selected by remember(profile) { mutableStateOf<Int?>(null) }
    var pendingDownload by remember(profile) { mutableStateOf<Pair<BackupApi, RemoteAsset>?>(null) }
    fun download(connection: BackupApi, asset: RemoteAsset) { scope.launch {
        notice = "正在下载：${asset.resources.firstOrNull { it.role == "primary" }?.filename ?: "媒体"}"
        try {
            val name = withContext(Dispatchers.IO) { RemoteLibrary.restore(context, connection, asset, profile) }
            if (config.profile == profile) notice = "已保存：$name"
        } catch (e: Exception) { if (config.profile == profile) notice = "保存失败：${e.message}" }
    } }
    val savePermission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val pending = pendingDownload; pendingDownload = null
        if (granted && pending != null && config.profile == profile) download(pending.first, pending.second)
        else notice = "保存到手机需要写入照片的权限"
    }
    val seen = remember(profile) { mutableSetOf<String>() }
    fun load(reset: Boolean) {
        if (!reset && (loading || (started && cursor == null))) return
        if (reset) { generation++; assets = emptyList(); cursor = null; started = false; seen.clear() }
        val requestGeneration = generation
        val requestedCursor = cursor
        val requestedTrash = trash
        val requestedFavorite = favorites
        val requestedAlbum = albumId
        val requestedFilters = filters
        val credentials = config.connection()
        val server = credentials.server
        val user = credentials.username
        val password = credentials.password
        val token = credentials.token
        loading = true
        scope.launch {
            try {
                val result = withContext(Dispatchers.IO) {
                    val connection = BackupApi(server, token)
                    if (token.isBlank()) {
                        val bearer = connection.bootstrap(user, password, Build.MODEL)
                        if (config.profile == profile) config.acceptBootstrap(connection, bearer, profile)
                    }
                    check(config.profile == profile) { "账户已切换" }
                    val bound = config.connection()
                    TransferStore.command(TransferStore.open(context, profile).handle, "bind", org.json.JSONObject()
                        .put("server", bound.server).put("account_id", bound.accountId).put("device_id", bound.deviceId))
                    val albumRows = if (reset) runCatching { connection.listAlbums() }.getOrNull() else null
                    Triple(connection, GalleryCache.page(context, profile, connection, requestedCursor, requestedTrash, requestedFavorite, requestedAlbum, requestedFilters), albumRows)
                }
                if (config.profile == profile && requestGeneration == generation) {
                    val page = result.second
                    check(page.nextCursor == null || seen.add(page.nextCursor)) { "分页游标重复，请刷新" }
                    result.third?.let { rows -> albums = (0 until rows.length()).map { i ->
                        rows.getJSONObject(i).getString("album_id") to rows.getJSONObject(i).getString("name") } }
                    api = result.first
                    assets = (assets + page.items).distinctBy { it.id }
                    cursor = page.nextCursor
                    started = true
                    notice = "${if (page.cached) "离线缓存 · " else ""}已加载 ${assets.size} 项"
                }
            } catch (error: Exception) {
                if (requestGeneration == generation && config.profile == profile) notice = error.message ?: "加载失败"
            } finally { if (requestGeneration == generation) loading = false }
        }
    }
    LaunchedEffect(profile) { if (config.serverUrl.isNotBlank()) load(true) }
    LaunchedEffect(api, profile) {
        val connection = api ?: return@LaunchedEffect
        withContext(Dispatchers.IO) { runCatching { connection.devices() }.getOrNull() }?.let { values ->
            devices = (0 until values.length()).map { values.getJSONObject(it).let { d -> d.getString("device_id") to d.getString("name") } }
        }
        while (true) {
            try {
                val changed = withContext(Dispatchers.IO) { GalleryCache.synchronize(context, profile, connection) }
                if (changed && !loading && selected == null) load(true)
            } catch (e: kotlinx.coroutines.CancellationException) { throw e }
            catch (e: Exception) { notice = "图库缓存待同步：${e.message}" }
            kotlinx.coroutines.delay(30_000)
        }
    }
    Column(Modifier.fillMaxSize()) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            FilledTonalButton(onClick = { showFilters = true }) { Text("筛选") }
            TextButton(onClick = { load(true) }) { Text("刷新") }
            TextButton(onClick = { trash = !trash; load(true) }) { Text(if (trash) "返回云端" else "回收站") }
            TextButton(onClick = { favorites = !favorites; load(true) }) { Text(if (favorites) "全部" else "收藏") }
        }
        if (notice.isNotEmpty()) Text(notice, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyVerticalGrid(columns = GridCells.Adaptive(105.dp), modifier = Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (assets.isEmpty() && !loading) item(span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.fillMaxWidth().padding(vertical = 36.dp)) {
                    Text("没有找到照片", style = MaterialTheme.typography.titleMedium)
                    Text("调整筛选条件，或从本地图库备份照片。", style = MaterialTheme.typography.bodySmall)
                }
            }
            itemsIndexed(assets, key = { _, asset -> asset.id }) { index, asset ->
                Column(Modifier.clickable { selected = index }) {
                    RemoteImage(context, api, profile, asset, false, Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(10.dp)))
                    if (asset.mediaKind == "video") Text("视频", style = MaterialTheme.typography.labelSmall)
                    Text(DateFormat.getDateInstance().format(Date(asset.createdAtMs)), style = MaterialTheme.typography.labelSmall)
                }
            }
            if (cursor != null) item(span = { GridItemSpan(maxLineSpan) }) {
                LaunchedEffect(cursor) { load(false) }
                TextButton(onClick = { load(false) }, enabled = !loading) { Text("加载更多") }
            }
        }
    }
    if (showFilters) ModalBottomSheet(onDismissRequest = { showFilters = false }) {
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("筛选云端照片", style = MaterialTheme.typography.titleLarge)
        Box {
            TextButton(onClick = { albumMenu = true }) { Text(albums.firstOrNull { it.first == albumId }?.second ?: "所有云端相册") }
            DropdownMenu(expanded = albumMenu, onDismissRequest = { albumMenu = false }) {
                DropdownMenuItem(text = { Text("所有云端相册") }, onClick = { albumId = null; albumMenu = false; load(true) })
                albums.forEach { (id, name) -> DropdownMenuItem(text = { Text(name) }, onClick = { albumId = id; albumMenu = false; load(true) }) }
            }
        }
        Row {
            TextButton(onClick = { filters = filters.copy(kind = when(filters.kind) { null -> "photo"; "photo" -> "video"; else -> null }); load(true) }) {
                Text(when(filters.kind) { "photo" -> "照片"; "video" -> "视频"; else -> "全部类型" })
            }
            Box { TextButton(onClick = { deviceMenu = true }) { Text(devices.firstOrNull { it.first == filters.device }?.second ?: "所有设备") }
                DropdownMenu(deviceMenu, { deviceMenu = false }) {
                    DropdownMenuItem(text = { Text("所有设备") }, onClick = { filters = filters.copy(device = null); deviceMenu = false; load(true) })
                    devices.forEach { (id, name) -> DropdownMenuItem(text = { Text(name) }, onClick = { filters = filters.copy(device = id); deviceMenu = false; load(true) }) }
                }
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedTextField(fromDate, { fromDate = it }, Modifier.fillMaxWidth(), label = { Text("开始 yyyy-MM-dd") }, singleLine = true)
            OutlinedTextField(toDate, { toDate = it }, Modifier.fillMaxWidth(), label = { Text("结束（不含）") }, singleLine = true)
            TextButton(onClick = {
                try {
                    fun parse(value: String): Long? = value.takeIf { it.isNotBlank() }?.let { java.time.LocalDate.parse(it).atStartOfDay(java.time.ZoneId.systemDefault()).toInstant().toEpochMilli() }
                    val from = parse(fromDate); val to = parse(toDate)
                    require(from == null || to == null || from < to)
                    filters = filters.copy(from = from, to = to); load(true)
                } catch (_: Exception) { notice = "请输入有效日期，结束日期应晚于开始日期" }
            }) { Text("应用") }
        }
            Button(onClick = { showFilters = false }, modifier = Modifier.fillMaxWidth()) { Text("完成") }
        }
    }
    selected?.let { index ->
        api?.let { connection ->
            PhotoViewerScreen(context, connection, profile, assets, index, onClose = { selected = null },
                onSave = { asset ->
                    if (Build.VERSION.SDK_INT < 29 && ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE) != PackageManager.PERMISSION_GRANTED) {
                        pendingDownload = connection to asset; savePermission.launch(Manifest.permission.WRITE_EXTERNAL_STORAGE)
                    } else download(connection, asset)
                },
                onFavorite = { asset -> scope.launch {
                    try { withContext(Dispatchers.IO) { connection.updateAsset(asset.id, favorite = !asset.favorite) }; selected = null; load(true) }
                    catch (e: Exception) { notice = e.message ?: "更新失败" }
                } }, onAction = { asset, operation, tag -> scope.launch {
                    try {
                        withContext(Dispatchers.IO) {
                            when (operation) {
                                "archive" -> connection.updateAsset(asset.id, archived = !asset.archived)
                                "trash" -> if (asset.trashed) connection.restoreAsset(asset.id) else connection.trashAsset(asset.id)
                                "tag" -> { val created = connection.createTag(tag); connection.addTagAsset(created.getString("tag_id"), asset.id) }
                            }
                        }
                        selected = null; load(true)
                    } catch (e: Exception) { notice = e.message ?: "更新失败" }
                } })
        }
    }
}

@Composable
internal fun RemoteImage(context: Context, api: BackupApi?, profile: String, asset: RemoteAsset, preview: Boolean, modifier: Modifier) {
    var bitmap by remember(profile, asset.id, preview) { mutableStateOf<Bitmap?>(null) }
    var error by remember(profile, asset.id, preview) { mutableStateOf("") }
    LaunchedEffect(profile, asset.id, preview, api) {
        val resource = if (preview && asset.mediaKind != "video") asset.resources.firstOrNull { it.role == "primary" }
            ?: asset.resources.firstOrNull { it.role != "thumbnail" } else asset.resources.firstOrNull { it.role == "thumbnail" }
        if (resource != null && api != null) {
            try {
                if (preview) asset.resources.firstOrNull { it.role == "thumbnail" }?.let {
                    bitmap = RemoteImageCache.load(context, api, profile, it, false)
                }
                bitmap = RemoteImageCache.load(context, api, profile, resource, preview)
            }
            catch (e: Exception) { error = e.message ?: "图片加载失败" }
        }
    }
    Box(modifier) {
        bitmap?.let { Image(it.asImageBitmap(), asset.resources.firstOrNull()?.filename,
            Modifier.fillMaxSize(), contentScale = if (preview) ContentScale.Fit else ContentScale.Crop) }
            ?: Text(if (error.isNotBlank()) error else if (asset.mediaKind == "video") "视频封面" else "暂无预览")
    }
}

@Composable
internal fun PhotoViewerScreen(context: Context, api: BackupApi, profile: String, assets: List<RemoteAsset>, index: Int,
    onClose: () -> Unit, onSave: (RemoteAsset) -> Unit, onFavorite: (RemoteAsset) -> Unit,
    onAction: (RemoteAsset, String, String) -> Unit) {
    Dialog(onDismissRequest = onClose, properties = DialogProperties(usePlatformDefaultWidth = false)) {
        Surface(Modifier.fillMaxSize()) {
            Column {
                val pager = rememberPagerState(initialPage = index, pageCount = { assets.size })
                Row {
                    TextButton(onClick = onClose) { Text("关闭") }
                    TextButton(onClick = { onSave(assets[pager.currentPage]) }) { Text("保存到手机") }
                    TextButton(onClick = { onFavorite(assets[pager.currentPage]) }) { Text("切换收藏") }
                }
                var tag by remember { mutableStateOf("") }
                val current = assets[pager.currentPage]
                Row {
                    TextButton(onClick = { onAction(current, "archive", "") }) { Text(if (current.archived) "取消归档" else "归档") }
                    TextButton(onClick = { onAction(current, "trash", "") }) { Text(if (current.trashed) "撤销删除" else "移入回收站") }
                }
                Row {
                    OutlinedTextField(tag, { tag = it }, Modifier.weight(1f), label = { Text("标签") }, singleLine = true)
                    TextButton(enabled = tag.isNotBlank(), onClick = { onAction(current, "tag", tag.trim()) }) { Text("加标签") }
                }
                HorizontalPager(pager, Modifier.weight(1f), key = { assets[it].id }) { page ->
                    var zoom by remember { mutableFloatStateOf(1f) }
                    val asset = assets[page]
                    val primary = asset.resources.firstOrNull { it.role == "primary" }
                    if (asset.mediaKind == "video" && primary != null) CloudVideo(api, primary, pager.currentPage == page, Modifier.fillMaxSize())
                    else RemoteImage(context, api, profile, asset, true,
                        Modifier.fillMaxSize().pointerInput(Unit) {
                            detectTransformGestures { _, _, scale, _ -> zoom = (zoom * scale).coerceIn(1f, 5f) }
                        }.graphicsLayer(scaleX = zoom, scaleY = zoom))
                }
                Text("${pager.currentPage + 1} / ${assets.size} · 查看只使用应用缓存")
            }
        }
    }
}
