package org.sarmg.mediabackup

import android.Manifest
import android.content.Context
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        BackupScheduler.syncAutomatic(this, SecureConfig(this))
        setContent {
            MaterialTheme { AppNavigation(this) }
        }
    }
}

@Composable
private fun AppNavigation(context: Context) {
    val config = remember { SecureConfig(context) }
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var profile by remember { mutableStateOf(config.profile) }
    Scaffold(bottomBar = {
        NavigationBar {
            listOf("本地", "云端", "传输", "设置").forEachIndexed { index, title ->
                NavigationBarItem(selected = tab == index, onClick = { tab = index },
                    icon = { Text(listOf("▦", "☁", "⇅", "⚙")[index]) }, label = { Text(title) })
            }
        }
    }) { padding ->
        Box(Modifier.fillMaxSize().padding(padding).padding(12.dp)) {
            key(profile) {
                when (tab) {
                    0 -> LocalGalleryScreen(context, config, profile, onSubmitted = { tab = 2 })
                    1 -> CloudGalleryScreen(context, config, profile)
                    2 -> TransfersScreen(context, config, profile)
                    else -> SettingsScreen(context, config, onSaved = { profile = config.profile })
                }
            }
        }
    }
}

@Composable
private fun SettingsScreen(context: Context, config: SecureConfig, onSaved: () -> Unit) {
    val scope = rememberCoroutineScope()
    var server by remember { mutableStateOf(config.serverUrl) }
    var username by remember { mutableStateOf(config.username) }
    var password by remember { mutableStateOf(config.password) }
    var auto by remember { mutableStateOf(config.autoBackup) }
    var wifi by remember { mutableStateOf(config.wifiOnly) }
    var charging by remember { mutableStateOf(config.chargingOnly) }
    var photos by remember { mutableStateOf(config.backupPhotos) }
    var videos by remember { mutableStateOf(config.backupVideos) }
    var camera by remember { mutableStateOf(config.cameraOnly) }
    var albums by remember { mutableStateOf<List<DeviceAlbum>>(emptyList()) }
    var selected by remember { mutableStateOf(config.selectedAlbumIds) }
    var notice by remember { mutableStateOf("") }
    var cacheLimit by remember { mutableIntStateOf(RemoteImageCache.limit(context)) }
    fun loadAlbums() { scope.launch { albums = withContext(Dispatchers.IO) { DeviceAlbums.list(context) } } }
    val permissions = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { loadAlbums() }
    LazyColumn(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        item { Text("设置", style = MaterialTheme.typography.headlineMedium) }
        item { OutlinedTextField(server, { server = it }, label = { Text("HTTPS 服务器根地址") }, modifier = Modifier.fillMaxWidth()) }
        item { OutlinedTextField(username, { username = it }, label = { Text("备份账户") }, modifier = Modifier.fillMaxWidth()) }
        item { OutlinedTextField(password, { password = it }, label = { Text("密码") }, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.fillMaxWidth()) }
        item { SettingToggle("自动备份", auto) { auto = it } }
        item { SettingToggle("仅 Wi-Fi", wifi) { wifi = it } }
        item { SettingToggle("仅充电时上传", charging) { charging = it } }
        item { SettingToggle("自动备份照片", photos) { photos = it } }
        item { SettingToggle("自动备份视频", videos) { videos = it } }
        item { SettingToggle("仅相机目录", camera) { camera = it } }
        item {
            Text("手动选择不受自动相册与类型限制。关闭相册不会删除云端副本。")
            TextButton(onClick = {
                permissions.launch(if (Build.VERSION.SDK_INT >= 34) arrayOf(Manifest.permission.READ_MEDIA_IMAGES,
                    Manifest.permission.READ_MEDIA_VIDEO, Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED)
                    else if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
                    else arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE))
            }) { Text("授权并读取自动备份相册") }
        }
        if (!camera) items(albums, key = { it.id }) { album ->
            SettingToggle(album.name, album.id in selected) { enabled -> selected = if (enabled) selected + album.id else selected - album.id }
        }
        item {
            Button(onClick = {
                try {
                    BackupApi(server.trim().trimEnd('/'), "")
                    require(username.isNotBlank() && password.isNotBlank()) { "请输入备份账户和密码" }
                    require(!auto || photos || videos) { "自动备份至少选择一种媒体类型" }
                    if (profileKey(server, username) != config.profile) {
                        androidx.work.WorkManager.getInstance(context).cancelAllWorkByTag(BackupScheduler.TAG)
                        config.saveSnapshot(BackupSnapshot())
                    }
                    config.saveCredentials(server, username, password)
                    config.autoBackup = auto; config.wifiOnly = wifi; config.chargingOnly = charging
                    config.backupPhotos = photos; config.backupVideos = videos; config.cameraOnly = camera
                    config.selectedAlbumIds = selected
                    BackupScheduler.syncAutomatic(context, config)
                    notice = "设置已保存"; onSaved()
                } catch (e: Exception) { notice = e.message ?: "设置无效" }
            }) { Text("保存设置") }
            Text(notice)
            Text("图片缓存：内存 24 MiB，磁盘 $cacheLimit MiB", style = MaterialTheme.typography.bodySmall)
            Slider(cacheLimit.toFloat(), { cacheLimit = (it.toInt() / 64) * 64 }, valueRange = 64f..1024f, steps = 14,
                onValueChangeFinished = { RemoteImageCache.setLimit(context, cacheLimit) })
            TextButton(onClick = { scope.launch { withContext(Dispatchers.IO) { RemoteImageCache.clear(context) }; notice = "浏览图片缓存已清空" } }) { Text("清空浏览图片缓存") }
        }
    }
}

@Composable
private fun SettingToggle(label: String, value: Boolean, changed: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        Text(label, Modifier.weight(1f)); Switch(value, changed)
    }
}
