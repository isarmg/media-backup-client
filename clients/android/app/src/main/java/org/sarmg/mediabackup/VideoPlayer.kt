package org.sarmg.mediabackup

import android.net.Uri
import android.widget.VideoView
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.ui.PlayerView

@androidx.annotation.OptIn(androidx.media3.common.util.UnstableApi::class)
@Composable
internal fun CloudVideo(api: BackupApi, resource: RemoteResource, active: Boolean, modifier: Modifier) {
    val context = LocalContext.current
    val player = remember(api, resource.id) {
        ExoPlayer.Builder(context).setMediaSourceFactory(DefaultMediaSourceFactory(api.videoFactory())).build().apply {
            setMediaItem(MediaItem.fromUri(api.resolve(resource.contentPath))); prepare()
        }
    }
    LaunchedEffect(active) { if (!active) player.pause() }
    DisposableEffect(player) { onDispose { player.release() } }
    AndroidView(factory = { PlayerView(it).apply { this.player = player; useController = true } }, modifier = modifier)
}
@Composable
internal fun LocalVideo(uri: Uri, modifier: Modifier) {
    var view by remember { mutableStateOf<VideoView?>(null) }
    DisposableEffect(uri) { onDispose { view?.stopPlayback() } }
    AndroidView(factory = { context -> VideoView(context).also { video ->
        view = video; video.setVideoURI(uri)
        video.setMediaController(android.widget.MediaController(context).apply { setAnchorView(video) })
        video.setOnPreparedListener { video.start() }
    } }, modifier = modifier)
}
