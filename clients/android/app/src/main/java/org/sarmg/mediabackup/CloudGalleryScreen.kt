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
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

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
    var loadError by remember(profile) { mutableStateOf<String?>(null) }
    var trash by remember(profile) { mutableStateOf(false) }
    var favorites by remember(profile) { mutableStateOf(false) }
    var albums by remember(profile) { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    var albumId by remember(profile) { mutableStateOf<String?>(null) }
    var showFilters by remember { mutableStateOf(false) }
    var optionsMenu by remember { mutableStateOf(false) }
    var gridMenu by remember { mutableStateOf(false) }
    var gridColumns by rememberSaveable(profile) { mutableIntStateOf(3) }
    var albumMenu by remember(profile) { mutableStateOf(false) }
    var filters by remember(profile) { mutableStateOf(CloudFilters()) }
    var devices by remember(profile) { mutableStateOf<List<Pair<String, String>>>(emptyList()) }
    var deviceMenu by remember { mutableStateOf(false) }
    var fromDate by remember { mutableStateOf("") }
    var toDate by remember { mutableStateOf("") }
    var generation by remember(profile) { mutableIntStateOf(0) }
    var selected by remember(profile) { mutableStateOf<Int?>(null) }
    var duplicateGroups by remember(profile) { mutableStateOf<org.json.JSONArray?>(null) }
    var pendingDownload by remember(profile) { mutableStateOf<Pair<BackupApi, RemoteAsset>?>(null) }
    val hasFilters = favorites || albumId != null || filters != CloudFilters()
    val monthFormat = remember { SimpleDateFormat("yyyy年M月", Locale.getDefault()) }
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
        if (reset) { generation++; assets = emptyList(); cursor = null; started = false; seen.clear(); loadError = null }
        val requestGeneration = generation
        val requestedCursor = cursor
        val requestedTrash = trash
        val requestedFavorite = favorites
        val requestedAlbum = albumId
        val requestedFilters = filters
        val credentials = config.connection()
        val server = credentials.server
        val authorizationCode = credentials.authorizationCode
        val token = credentials.token
        loading = true
        scope.launch {
            try {
                val result = withContext(Dispatchers.IO) {
                    check(token.isNotBlank()) { "客户端需要使用当前实例授权码重新配对" }
                    val connection = BackupApi(server, token)
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
                    loadError = null
                    notice = if (page.cached) "正在显示离线缓存" else ""
                }
            } catch (error: Exception) {
                if (requestGeneration == generation && config.profile == profile) {
                    loadError = error.message ?: "加载失败"
                    notice = loadError.orEmpty()
                }
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
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            FilledTonalButton(onClick = { showFilters = true }) { Text("筛选") }
            FilterChip(selected = favorites, onClick = { favorites = !favorites; load(true) }, label = { Text("收藏") })
            Spacer(Modifier.weight(1f))
            Box {
                TextButton(onClick = { gridMenu = true }) { Text("视图") }
                DropdownMenu(gridMenu, { gridMenu = false }) {
                    DropdownMenuItem(text = { Text("放大缩略图") }, enabled = gridColumns > 2,
                        onClick = { gridColumns--; gridMenu = false })
                    DropdownMenuItem(text = { Text("缩小缩略图") }, enabled = gridColumns < 5,
                        onClick = { gridColumns++; gridMenu = false })
                }
            }
            Box {
                TextButton(onClick = { optionsMenu = true }) { Text("更多") }
                DropdownMenu(optionsMenu, { optionsMenu = false }) {
                    DropdownMenuItem(text = { Text("刷新图库") }, onClick = { optionsMenu = false; load(true) })
                    DropdownMenuItem(text = { Text(if (trash) "返回云端" else "打开回收站") }, onClick = {
                        optionsMenu = false; trash = !trash; load(true)
                    })
                    DropdownMenuItem(text = { Text("查看重复项") }, onClick = {
                        optionsMenu = false
                        val connection = api
                        if (connection != null) scope.launch {
                            try { duplicateGroups = withContext(Dispatchers.IO) { connection.duplicateGroups() } }
                            catch (error: Exception) { notice = error.message ?: "重复项加载失败" }
                        }
                    })
                }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = androidx.compose.ui.Alignment.CenterVertically) {
            Text("已载入 ${assets.size} 项${if (cursor != null) " · 可继续加载" else ""}", style = MaterialTheme.typography.bodyMedium)
            if (hasFilters) TextButton(onClick = {
                favorites = false; albumId = null; filters = CloudFilters(); fromDate = ""; toDate = ""; load(true)
            }) { Text("清除筛选") }
        }
        if (trash) Text("回收站", style = MaterialTheme.typography.titleSmall)
        if (notice.isNotEmpty() && (assets.isNotEmpty() || loading)) Text(notice, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
        LazyVerticalGrid(columns = GridCells.Fixed(gridColumns), modifier = Modifier.weight(1f).galleryGridPinch(gridColumns) { gridColumns = it },
            horizontalArrangement = Arrangement.spacedBy(3.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            if (assets.isEmpty() && !loading) item(span = { GridItemSpan(maxLineSpan) }) {
                Column(Modifier.fillMaxWidth().padding(vertical = 36.dp), horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    Text(if (loadError != null) "云端图库加载失败" else if (trash) "回收站为空" else if (hasFilters) "没有符合条件的照片" else "云端还没有照片",
                        style = MaterialTheme.typography.titleMedium)
                    Text(loadError ?: if (trash) "已移入回收站的媒体会显示在这里。" else if (hasFilters) "清除筛选后查看全部云端媒体。" else "从本地图库选择照片，开始备份。",
                        style = MaterialTheme.typography.bodySmall)
                    if (loadError != null || trash || hasFilters) Button(onClick = {
                        if (loadError == null) {
                            trash = false; favorites = false; albumId = null; filters = CloudFilters(); fromDate = ""; toDate = ""
                        }
                        load(true)
                    }) { Text(if (loadError != null) "重试" else if (trash) "返回全部照片" else "清除筛选") }
                }
            }
            assets.withIndex().groupBy { monthFormat.format(Date(it.value.createdAtMs)) }.forEach { (month, group) ->
                item(key = "month-$month", span = { GridItemSpan(maxLineSpan) }) {
                    Text(month, Modifier.fillMaxWidth().padding(vertical = 10.dp), style = MaterialTheme.typography.titleSmall)
                }
                items(group, key = { it.value.id }) { indexed ->
                    val asset = indexed.value
                    Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(8.dp))
                        .clickable { selected = indexed.index }
                        .semantics { contentDescription = "${if (asset.mediaKind == "video") "视频" else "照片"}，${asset.resources.firstOrNull { it.role == "primary" }?.filename ?: "未命名媒体"}" }) {
                        RemoteImage(context, api, profile, asset, false, Modifier.fillMaxSize())
                        if (asset.mediaKind == "video") Text("▶", Modifier.align(androidx.compose.ui.Alignment.BottomStart).padding(5.dp)
                            .background(androidx.compose.ui.graphics.Color.Black.copy(alpha = 0.6f), RoundedCornerShape(20.dp))
                            .padding(horizontal = 7.dp, vertical = 3.dp), color = androidx.compose.ui.graphics.Color.White,
                            style = MaterialTheme.typography.labelSmall)
                    }
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
                                "remove-tag" -> {
                                    val tags = connection.listTags()
                                    val existing = (0 until tags.length()).map(tags::getJSONObject)
                                        .firstOrNull { it.getString("name") == tag }
                                        ?: error("标签不存在")
                                    connection.removeTagAsset(existing.getString("tag_id"), asset.id)
                                }
                                "delete" -> connection.deleteAssetPermanently(asset.id)
                            }
                        }
                        selected = null; load(true)
                    } catch (e: Exception) { notice = e.message ?: "更新失败" }
                } })
        }
    }
    duplicateGroups?.let { groups ->
        ModalBottomSheet(onDismissRequest = { duplicateGroups = null }) {
            Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("重复项", style = MaterialTheme.typography.titleLarge)
                if (groups.length() == 0) Text("没有检测到内容相同的媒体。")
                for (index in 0 until groups.length()) {
                    val group = groups.getJSONObject(index)
                    val members = group.getJSONArray("assets")
                    ElevatedCard(Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp)) {
                            Text("第 ${index + 1} 组 · ${members.length()} 项", style = MaterialTheme.typography.titleMedium)
                            Text("${group.getLong("content_size")} 字节", style = MaterialTheme.typography.bodySmall)
                            for (member in 0 until members.length()) {
                                val asset = members.getJSONObject(member)
                                Text(asset.optString("source_asset_id", asset.getString("asset_id")), style = MaterialTheme.typography.bodySmall)
                            }
                        }
                    }
                }
                Button(onClick = { duplicateGroups = null }, modifier = Modifier.fillMaxWidth()) { Text("完成") }
            }
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
        if (bitmap == null && !preview) Text(if (error.isNotBlank()) error else if (asset.mediaKind == "video") "视频封面" else "暂无预览")
    }
}

@Composable
internal fun PhotoViewerScreen(context: Context, api: BackupApi, profile: String, assets: List<RemoteAsset>, index: Int,
    onClose: () -> Unit, onSave: (RemoteAsset) -> Unit, onFavorite: (RemoteAsset) -> Unit,
    onAction: (RemoteAsset, String, String) -> Unit) {
    FullScreenPhotoDialog(onClose = onClose) {
        val pager = rememberPagerState(initialPage = index, pageCount = { assets.size })
        var menu by remember { mutableStateOf(false) }
        var addingTag by remember { mutableStateOf(false) }
        var confirmingDelete by remember { mutableStateOf(false) }
        var tag by remember { mutableStateOf("") }
        val current = assets[pager.currentPage]
        Box(Modifier.fillMaxSize()) {
            HorizontalPager(pager, Modifier.fillMaxSize(), key = { assets[it].id }) { page ->
                val asset = assets[page]
                val primary = asset.resources.firstOrNull { it.role == "primary" }
                if (asset.mediaKind == "video" && primary != null) {
                    CloudVideo(api, primary, pager.currentPage == page, Modifier.fillMaxSize())
                } else {
                    ZoomablePhotoFrame(onTap = onClose, onLongPress = { menu = true }) { imageModifier ->
                        RemoteImage(context, api, profile, asset, true, imageModifier)
                    }
                }
            }
            if (current.mediaKind == "video") {
                Row(Modifier.fillMaxWidth().align(androidx.compose.ui.Alignment.TopCenter), horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton(onClick = onClose) { Text("关闭") }
                    TextButton(onClick = { menu = true }) { Text("更多") }
                }
            }
            DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                DropdownMenuItem(text = { Text("保存到手机") }, onClick = { menu = false; onSave(current) })
                DropdownMenuItem(text = { Text(if (current.favorite) "取消收藏" else "收藏") }, onClick = { menu = false; onFavorite(current) })
                DropdownMenuItem(text = { Text(if (current.archived) "取消归档" else "归档") }, onClick = { menu = false; onAction(current, "archive", "") })
                DropdownMenuItem(text = { Text("添加标签") }, onClick = { menu = false; tag = ""; addingTag = true })
                current.tagNames.forEach { existing ->
                    DropdownMenuItem(text = { Text("移除标签：$existing") }, onClick = { menu = false; onAction(current, "remove-tag", existing) })
                }
                DropdownMenuItem(text = { Text(if (current.trashed) "恢复照片" else "移入回收站") }, onClick = { menu = false; onAction(current, "trash", "") })
                if (current.trashed) DropdownMenuItem(text = { Text("永久删除") }, onClick = { menu = false; confirmingDelete = true })
            }
            if (addingTag) AlertDialog(onDismissRequest = { addingTag = false }, title = { Text("添加标签") },
                text = { OutlinedTextField(tag, { tag = it }, label = { Text("标签名称") }, singleLine = true) },
                confirmButton = { TextButton(enabled = tag.isNotBlank(), onClick = { addingTag = false; onAction(current, "tag", tag.trim()) }) { Text("添加") } },
                dismissButton = { TextButton(onClick = { addingTag = false }) { Text("取消") } })
            if (confirmingDelete) AlertDialog(onDismissRequest = { confirmingDelete = false }, title = { Text("永久删除照片？") },
                text = { Text("此操作无法撤销。服务器可能在后台继续回收未引用的文件。") },
                confirmButton = { TextButton(onClick = { confirmingDelete = false; onAction(current, "delete", "") }) { Text("永久删除") } },
                dismissButton = { TextButton(onClick = { confirmingDelete = false }) { Text("取消") } })
        }
    }
}
