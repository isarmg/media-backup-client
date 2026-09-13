package org.sarmg.mediabackup

import android.content.Context
import android.os.Build
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import org.json.JSONObject
import java.util.concurrent.TimeUnit

@Composable
internal fun AccountDialog(context: Context, config: SecureConfig, onDismiss: () -> Unit, onLoggedIn: () -> Unit) {
    val scope = rememberCoroutineScope()
    var server by remember { mutableStateOf(config.serverUrl) }
    var authorizationCode by remember { mutableStateOf(config.authorizationCode) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text("配对备份实例") },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("连接你的媒体库，备份所选照片并浏览云端媒体。")
            OutlinedTextField(server, { server = it }, label = { Text("HTTPS 服务器根地址") },
                placeholder = { Text("https://backup.example.com") }, singleLine = true, enabled = !busy,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(authorizationCode, { authorizationCode = it }, label = { Text("实例授权码") }, singleLine = true,
                enabled = !busy, modifier = Modifier.fillMaxWidth())
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (error.isNotEmpty()) Text(error, color = MaterialTheme.colorScheme.error)
            Text("授权码仅保存在系统加密存储中；服务端更换授权码后需要重新配对。", style = MaterialTheme.typography.bodySmall)
        } },
        confirmButton = { TextButton(enabled = !busy && server.isNotBlank() && authorizationCode.isNotBlank(), onClick = {
            busy = true; error = ""
            val expected = config.connection()
            val address = server.trim().trimEnd('/')
            val code = authorizationCode.trim()
            scope.launch {
                try {
                    val result = withContext(Dispatchers.IO) {
                        val client = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build()
                        val api = BackupApi(address, "", client)
                        val token = api.bootstrap(code, Build.MODEL)
                        check(token.isNotBlank()) { "服务器没有返回有效登录凭据" }
                        check(config.connection() == expected) { "账户已改变，请重新登录" }
                        val store = TransferStore.bindAccount(context, address, code, api.accountId, api.deviceId)
                        Triple(api, token, store.profile)
                    }
                    config.saveAuthenticatedConnection(expected, address, code, result.first, result.second, result.third)
                    withContext(Dispatchers.IO) {
                        androidx.work.WorkManager.getInstance(context).cancelAllWorkByTag(BackupScheduler.TAG).result.get()
                    }
                    config.saveSnapshot(BackupSnapshot(message = "实例已配对"))
                    BackupScheduler.syncAutomatic(context, config)
                    onLoggedIn()
                } catch (e: kotlinx.coroutines.CancellationException) { throw e }
                catch (e: Exception) { error = e.message ?: "配对失败，请检查服务器地址和授权码" }
                finally { busy = false }
            }
        }) { Text(if (busy) "正在配对…" else "配对") } },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text("取消") } },
    )
}
