package org.sarmg.xszc

import android.Manifest
import android.content.ContentValues
import android.content.Context
import android.content.ContextWrapper
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.lifecycle.Lifecycle
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.rules.ExternalResource
import java.io.File
import java.util.UUID

@RunWith(AndroidJUnit4::class)
class GalleryNavigationInstrumentedTest {
    @get:Rule(order = 0) val preferences = object : ExternalResource() {
        override fun before() {
            val instrumentation = InstrumentationRegistry.getInstrumentation()
            val target = instrumentation.targetContext
            if (Build.VERSION.SDK_INT >= 33) {
                instrumentation.uiAutomation.grantRuntimePermission(target.packageName, Manifest.permission.READ_MEDIA_IMAGES)
                instrumentation.uiAutomation.grantRuntimePermission(target.packageName, Manifest.permission.READ_MEDIA_VIDEO)
            } else instrumentation.uiAutomation.grantRuntimePermission(target.packageName, Manifest.permission.READ_EXTERNAL_STORAGE)
            target.getSharedPreferences("gallery_ui", Context.MODE_PRIVATE)
                .edit().putInt("columns", 3).commit()
        }
    }
    @get:Rule(order = 1) val compose = createAndroidComposeRule<MainActivity>()
    private val context get() = compose.activity
    private val photos = mutableListOf<Uri>()

    @Before fun seedGallery() {
        repeat(40) { photos += insertPhoto(it) }
        compose.waitUntil(30_000) { runCatching { compose.onAllNodes(hasTestTagPrefix("gallery.photo.")).fetchSemanticsNodes().isNotEmpty() }.getOrDefault(false) }
        compose.waitUntil(30_000) { compose.onNodeWithTag("gallery.filter").isEnabled() }
    }

    private fun insertPhoto(index: Int): Uri {
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "layout-test-$index-${UUID.randomUUID()}.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/XszcLayoutTest")
            put(MediaStore.Images.Media.DATE_TAKEN, if (index >= 1000) 1_800_000_000_000L else 1_750_000_000_000L + index * 86_400_000L)
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = context.contentResolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)!!
        val bitmap = Bitmap.createBitmap(160, 160, Bitmap.Config.ARGB_8888)
        bitmap.eraseColor(android.graphics.Color.rgb(40 + index % 150, 90, 170))
        context.contentResolver.openOutputStream(uri)!!.use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        bitmap.recycle()
        context.contentResolver.update(uri, ContentValues().apply { put(MediaStore.Images.Media.IS_PENDING, 0) }, null, null)
        return uri
    }

    @After fun clearFixtures() { photos.forEach { context.contentResolver.delete(it, null, null) } }

    private fun screenshot(name: String) {
        compose.waitForIdle()
        InstrumentationRegistry.getInstrumentation().waitForIdleSync()
        Thread.sleep(100)
        val dir = File(context.filesDir, "layout-screenshots").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use { InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot().compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test fun controlsStayFixedAndSelectionActionsAreOnRight() {
        val filter = compose.onNodeWithTag("gallery.filter").fetchSemanticsNode().boundsInRoot
        compose.onNodeWithTag("gallery.select").performClick()
        val all = compose.onNodeWithTag("gallery.select-all").fetchSemanticsNode().boundsInRoot
        val cancel = compose.onNodeWithTag("gallery.cancel").fetchSemanticsNode().boundsInRoot
        assertEquals(filter.height, compose.onNodeWithTag("gallery.filter").fetchSemanticsNode().boundsInRoot.height)
        assertTrue(all.left > filter.right && cancel.left > all.left)
        assertEquals(filter.top, all.top)
        assertEquals(filter.top, cancel.top)
        val date = compose.onAllNodes(hasTestTagPrefix("gallery.date.")).fetchSemanticsNodes().first().config[androidx.compose.ui.semantics.SemanticsProperties.TestTag]
        compose.onNodeWithTag("gallery.grid").performTouchInput { swipeUp() }
        compose.onNodeWithTag("gallery.filter").assertIsDisplayed()
        assertEquals(filter.top, compose.onNodeWithTag("gallery.filter").fetchSemanticsNode().boundsInRoot.top)
        compose.onNodeWithTag(date).assertIsNotDisplayed()
        screenshot("local-selection-scrolled")
        compose.onNodeWithText("添加").assertDoesNotExist()
        compose.onNodeWithText("保存备份偏好").assertDoesNotExist()
    }

    @Test fun pinchResizesPhotosAndPreviewUsesWholeScreen() {
        val originalWidth = firstPhoto().fetchSemanticsNode().boundsInRoot.width
        pinch(2f)
        val enlargedWidth = firstPhoto().fetchSemanticsNode().boundsInRoot.width
        assertTrue(enlargedWidth > originalWidth)
        screenshot("local-enlarged")
        pinch(0.3f)
        assertTrue(firstPhoto().fetchSemanticsNode().boundsInRoot.width < enlargedWidth)
        repeat(3) { pinch(0.3f) }
        val minimumWidth = firstPhoto().fetchSemanticsNode().boundsInRoot.width
        assertTrue(minimumWidth < originalWidth)
        pinch(0.3f)
        assertEquals(minimumWidth, firstPhoto().fetchSemanticsNode().boundsInRoot.width, 1f)
        screenshot("local-reduced")
        repeat(3) { pinch(4f) }
        val maximumWidth = firstPhoto().fetchSemanticsNode().boundsInRoot.width
        assertTrue(maximumWidth > originalWidth * 2.5f)
        pinch(2f)
        assertEquals(maximumWidth, firstPhoto().fetchSemanticsNode().boundsInRoot.width, 1f)
        firstPhoto().performClick()
        compose.onNodeWithContentDescription("照片预览，点按关闭，双指缩放").assertIsDisplayed()
        screenshot("full-screen-photo")
    }

    private fun firstPhoto(): SemanticsNodeInteraction = compose.onAllNodes(hasTestTagPrefix("gallery.photo.")).onFirst()

    private fun pinch(scale: Float) {
        compose.onNodeWithTag("gallery.grid").performTouchInput {
            val midpoint = center
            val distance = 80f
            down(0, midpoint - Offset(distance, 0f)); down(1, midpoint + Offset(distance, 0f))
            for (step in 1..12) {
                val delta = distance * (1f + (scale - 1f) * step / 12f)
                moveTo(0, midpoint - Offset(delta, 0f), delayMillis = 16)
                moveTo(1, midpoint + Offset(delta, 0f), delayMillis = 16)
            }
            up(0); up(1)
        }
        compose.waitForIdle()
    }

    @Test fun nativeLoginAndImmediateSettingsRemainReachable() {
        compose.onNodeWithTag("gallery.backup").performClick()
        val field = compose.onNodeWithTag("account.server").fetchSemanticsNode().boundsInRoot
        val cancel = compose.onNodeWithTag("account.cancel").fetchSemanticsNode().boundsInRoot
        val submit = compose.onNodeWithTag("account.submit").fetchSemanticsNode().boundsInRoot
        assertEquals(cancel.width, submit.width, 1f)
        assertEquals(cancel.top, submit.top)
        assertEquals(field.left, cancel.left, 1f)
        assertEquals(field.right, submit.right, 1f)
        screenshot("native-login-default")
        compose.onNodeWithTag("account.server").assertIsDisplayed().performTextInput("http://example.com")
        compose.onNodeWithTag("account.password").performTextInput("test-code")
        compose.onNodeWithTag("account.submit").performClick()
        compose.waitUntil(10_000) { compose.onAllNodesWithText("服务器地址必须使用 HTTPS").fetchSemanticsNodes().isNotEmpty() }
        screenshot("native-login")
        compose.onNodeWithTag("account.cancel").performClick()
        compose.onNodeWithText("设置").performClick()
        compose.onNodeWithText("保存备份偏好").assertDoesNotExist()
        compose.onNodeWithText("登录 / 切换账户").assertDoesNotExist()
        compose.onNodeWithText("尚未登录").performClick()
        compose.onNodeWithTag("account.cancel").performClick()
        val before = SecureConfig(context).chargingOnly
        // The native switch is the third toggle in the preference list.
        compose.onAllNodes(isToggleable())[2].performClick()
        assertEquals(!before, SecureConfig(context).chargingOnly)
        compose.onNodeWithText("本地").performClick()
        compose.onNodeWithText("设置").performClick()
        assertEquals(!before, SecureConfig(context).chargingOnly)
        compose.onAllNodes(isToggleable())[2].performClick()
        compose.onNodeWithText("仅相机目录").assertDoesNotExist()
        compose.onNodeWithTag("settings.list").performScrollToNode(hasText("自动备份相册"))
        compose.onNodeWithText("自动备份相册").performClick()
        compose.onNodeWithTag("settings.list").performScrollToNode(hasText("仅相机目录"))
        compose.onNodeWithText("仅相机目录").assertIsDisplayed()
        compose.onNodeWithTag("settings.list").performScrollToNode(hasText("自动备份相册"))
        compose.onNodeWithText("自动备份相册").performClick()
        compose.onNodeWithText("仅相机目录").assertDoesNotExist()
        compose.onNodeWithTag("settings.list").performScrollToIndex(0)
        compose.onNodeWithText("照片权限设置").assertIsDisplayed()
        screenshot("settings")
        compose.onNodeWithText("照片权限设置").performClick()
        compose.waitUntil(10_000) {
            InstrumentationRegistry.getInstrumentation().uiAutomation.rootInActiveWindow?.packageName?.toString() == "com.android.settings"
        }
    }

    @Test fun mediaStoreChangesAutomaticallyRefreshGallery() {
        compose.waitUntil(30_000) { compose.onAllNodesWithText("已载入 40 项").fetchSemanticsNodes().isNotEmpty() }
        val uri = insertPhoto(50); photos += uri
        compose.waitUntil(30_000) { compose.onAllNodesWithText("已载入 41 项").fetchSemanticsNodes().isNotEmpty() }
    }

    @Test fun paginationRetainsLoadedPagesAfterResumeAndMediaStoreChanges() {
        repeat(321) { photos += insertPhoto(1000 + it) }
        compose.waitUntil(30_000) { compose.onNodeWithTag("gallery.filter").isEnabled() }
        loadNextPage(300)
        compose.activityRule.scenario.moveToState(Lifecycle.State.CREATED)
        compose.activityRule.scenario.moveToState(Lifecycle.State.RESUMED)
        compose.waitUntil(30_000) { compose.onNodeWithTag("gallery.filter").isEnabled() }
        compose.onNodeWithTag("gallery.grid").performScrollToIndex(0)
        compose.onNodeWithText("已载入 300 项").assertIsDisplayed()
        loadNextPage(361)
        compose.onNodeWithText("加载更多").assertDoesNotExist()
        photos += insertPhoto(1400)
        compose.waitUntil(30_000) { compose.onAllNodesWithText("已载入 362 项").fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("加载更多").assertDoesNotExist()
        compose.onNodeWithTag("gallery.filter").assertIsEnabled()
    }

    private fun loadNextPage(expected: Int) {
        compose.onNodeWithTag("gallery.grid").performScrollToNode(hasText("加载更多"))
        compose.onNodeWithText("加载更多").performClick()
        compose.onNodeWithTag("gallery.grid").performScrollToIndex(0)
        compose.waitUntil(30_000) { compose.onAllNodesWithText("已载入 $expected 项").fetchSemanticsNodes().isNotEmpty() }
        compose.waitUntil(30_000) { compose.onNodeWithTag("gallery.filter").isEnabled() }
    }

    @Test fun logoutPersistsAndKeepsReusableCredentials() {
        val prefix = "account-test-${UUID.randomUUID()}"
        val isolated = object : ContextWrapper(context) {
            override fun getApplicationContext(): Context = this
            override fun getSharedPreferences(name: String, mode: Int): SharedPreferences =
                super.getSharedPreferences("$prefix-$name", mode)
        }
        val config = SecureConfig(isolated)
        config.serverUrl = "https://backup.example.com"
        config.authorizationCode = "test-code"
        config.bearerToken = "test-token"
        config.accountId = "test-account"; config.deviceId = "test-device"
        assertTrue(config.isLoggedIn)
        config.logout()
        val reopened = SecureConfig(isolated)
        assertFalse(reopened.isLoggedIn)
        assertEquals("", reopened.connection().token)
        assertEquals("", reopened.authorizationCode)
        assertEquals("test-token", reopened.savedConnection().token)
        assertEquals("test-code", reopened.savedAuthorizationCode)
    }

    private fun hasTestTagPrefix(prefix: String) = SemanticsMatcher("tag starts with $prefix") {
        it.config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.TestTag)?.startsWith(prefix) == true
    }
    private fun SemanticsNodeInteraction.isEnabled(): Boolean =
        fetchSemanticsNode().config.getOrNull(androidx.compose.ui.semantics.SemanticsProperties.Disabled) == null
}
