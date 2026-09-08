package org.sarmg.mediabackup

import android.content.ContextWrapper
import android.system.Os
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.UUID

/** Actual JNI and Android sandbox: no mocked native results or production data. */
@RunWith(AndroidJUnit4::class)
class NativeStorageInstrumentedTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var root: File

    @Before fun setUp() {
        root = File(context.dataDir.canonicalFile, "native-test-${UUID.randomUUID()}")
        Os.mkdir(root.path, 0x1c0)
    }

    @After fun tearDown() {
        // Tests unlink their synthetic symlinks before deleting this isolated fixture.
        Os.chmod(root.path, 0x1c0)
        root.deleteRecursively()
    }

    private fun storage(dataRoot: File = root): NativeStorage.Paths =
        NativeStorage.prepare(object : ContextWrapper(context) {
            override fun getDataDir(): File = dataRoot
        })

    private fun open(paths: NativeStorage.Paths): Long = NativeBridgeV2.open(
        paths.database.path,
        MobileContractV02.putIdentity(JSONObject()).put("part_size", 16).toString(),
    )

    @Test fun prepareUploadAndReopenActualDatabase() {
        val paths = storage()
        val source = File(root, "source.jpg")
        val bytes = ByteArray(39) { it.toByte() }
        source.writeBytes(bytes)
        Os.chmod(source.path, 0x180)
        val input = MobileContractV02.putIdentity(JSONObject())
            .put("source_asset_id", "fixture-asset")
            .put("source_resource_id", "fixture-resource")
            .put("media_kind", "photo")
            .put("role", "primary")
            .put("file_path", source.path)
            .put("filename", "source.jpg")
            .put("mime_type", "image/jpeg")
            .put("source_created_at_ms", 1)
            .put("modified_ms", 1)
            .put("source_size", source.length())
            .put("metadata_json", JSONObject.NULL)
            .put("remove_source_after_prepare", false)
        // Model shared Android ancestors: traversal is allowed but listing is not.
        Os.chmod(root.path, 0x49) // 0111
        val handle = open(paths)
        try {
            MobileContractV02.requireEnvelope(NativeBridgeV2.enqueue(handle, input.toString()))
            val job = MobileContractV02.requireEnvelope(NativeBridgeV2.next(handle, paths.staging.path))
                .getJSONObject("value")
            val jobId = job.getString("job_id")
            val parts = job.getJSONArray("local_parts")
            assertEquals(3, parts.length())
            val reconstructed = (0 until parts.length()).flatMap { index ->
                File(parts.getJSONObject(index).getString("path")).readBytes().toList()
            }.toByteArray()
            assertArrayEquals(bytes, reconstructed)
            MobileContractV02.requireEnvelope(NativeBridgeV2.markUpload(handle, jobId, UUID.randomUUID().toString()))
            for (index in 0 until parts.length()) {
                MobileContractV02.requireEnvelope(NativeBridgeV2.markPart(handle, jobId, index))
            }
            MobileContractV02.requireEnvelope(NativeBridgeV2.markComplete(handle, jobId))
        } finally {
            NativeBridgeV2.close(handle)
        }
        val reopened = open(storage())
        try {
            assertFalse(NativeBridgeV2.needs(reopened, "fixture-asset", "fixture-resource", 1))
            MobileContractV02.requireEnvelope(NativeBridgeV2.stats(reopened))
            assertTrue(MobileContractV02.requireEnvelope(NativeBridgeV2.next(reopened, paths.staging.path)).isNull("value"))
        } finally {
            NativeBridgeV2.close(reopened)
        }
    }

    @Test fun resolvesOnlySystemProvidedRootAlias() {
        val alias = File(root, "system-root-alias")
        Os.symlink(root.path, alias.path)
        try {
            val paths = storage(alias)
            assertEquals(root.path, paths.database.parentFile!!.parent)
            val handle = open(paths)
            NativeBridgeV2.close(handle)
        } finally {
            Os.unlink(alias.path)
        }
    }

    @Test fun repairsOwnedStagingPermissionsWithoutLosingFiles() {
        val paths = storage()
        val retained = File(paths.staging, "retained")
        retained.writeText("unchanged")
        Os.chmod(paths.staging.path, 0x1ed) // 0755: old Java mkdirs mode
        storage()
        assertEquals(0x1c0, Os.stat(paths.staging.path).st_mode and 0x1ff)
        assertEquals("unchanged", retained.readText())
    }

    @Test fun refusesChildDirectoryLinks() {
        val target = File(root, "target")
        Os.mkdir(target.path, 0x1ed)
        val link = File(root, "databases")
        Os.symlink(target.path, link.path)
        try {
            assertThrows(Exception::class.java) { storage() }
            assertEquals(0x1ed, Os.stat(target.path).st_mode and 0x1ff)
        } finally {
            Os.unlink(link.path)
        }
    }

    @Test fun refusesDatabaseFileLinksWithoutChangingTarget() {
        val paths = storage()
        val target = File(root, "untouched")
        target.writeText("do not modify")
        Os.symlink(target.path, paths.database.path)
        try {
            assertThrows(RuntimeException::class.java) { open(paths) }
            assertEquals("do not modify", target.readText())
        } finally {
            Os.unlink(paths.database.path)
        }
    }
}
