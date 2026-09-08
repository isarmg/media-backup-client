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
import androidx.compose.ui.text.input.PasswordVisualTransformation
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
    var username by remember { mutableStateOf(config.username) }
    var password by remember { mutableStateOf(config.password) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf("") }
    AlertDialog(
        onDismissRequest = { if (!busy) onDismiss() },
        title = { Text("登录账户") },
        text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text("连接你的媒体库，备份所选照片并浏览云端媒体。")
            OutlinedTextField(server, { server = it }, label = { Text("HTTPS 服务器根地址") },
                placeholder = { Text("https://backup.example.com") }, singleLine = true, enabled = !busy,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri), modifier = Modifier.fillMaxWidth())
            OutlinedTextField(username, { username = it }, label = { Text("账户") }, singleLine = true,
                enabled = !busy, modifier = Modifier.fillMaxWidth())
            OutlinedTextField(password, { password = it }, label = { Text("密码") }, singleLine = true,
                enabled = !busy, visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password), modifier = Modifier.fillMaxWidth())
            if (busy) LinearProgressIndicator(Modifier.fillMaxWidth())
            if (error.isNotEmpty()) Text(error, color = MaterialTheme.colorScheme.error)
            Text("验证成功后保存登录信息。", style = MaterialTheme.typography.bodySmall)
        } },
        confirmButton = { TextButton(enabled = !busy && server.isNotBlank() && username.isNotBlank() && password.isNotEmpty(), onClick = {
            busy = true; error = ""
            val expected = config.connection()
            val address = server.trim().trimEnd('/')
            val user = username.trim()
            val secret = password
            scope.launch {
                try {
                    val result = withContext(Dispatchers.IO) {
                        val client = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build()
                        val api = BackupApi(address, "", client)
                        val token = api.bootstrap(user, secret, Build.MODEL)
                        check(token.isNotBlank()) { "服务器没有返回有效登录凭据" }
                        check(config.connection() == expected) { "账户已改变，请重新登录" }
                        val store = TransferStore.bindAccount(context, address, user, api.accountId, api.deviceId)
                        Triple(api, token, store.profile)
                    }
                    config.saveAuthenticatedConnection(expected, address, user, secret, result.first, result.second, result.third)
                    withContext(Dispatchers.IO) {
                        androidx.work.WorkManager.getInstance(context).cancelAllWorkByTag(BackupScheduler.TAG).result.get()
                    }
                    config.saveSnapshot(BackupSnapshot(message = "已登录：$user"))
                    BackupScheduler.syncAutomatic(context, config)
                    onLoggedIn()
                } catch (e: kotlinx.coroutines.CancellationException) { throw e }
                catch (e: Exception) { error = e.message ?: "登录失败，请检查服务器地址和账户" }
                finally { busy = false }
            }
        }) { Text(if (busy) "正在登录…" else "登录") } },
        dismissButton = { TextButton(enabled = !busy, onClick = onDismiss) { Text("取消") } },
    )
}
