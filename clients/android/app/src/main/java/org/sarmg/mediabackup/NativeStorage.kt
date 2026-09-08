package org.sarmg.mediabackup

import android.content.Context
import android.os.Process
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File

/** Resolve only the Android-owned root alias; never follow links inside our storage. */
internal object NativeStorage {
    data class Paths(val database: File, val staging: File)

    fun prepare(context: Context): Paths {
        val root = context.dataDir.canonicalFile
        check(root.isDirectory) { "应用私有目录不可用" }
        val databases = privateDirectory(root, "databases")
        val files = privateDirectory(root, "files")
        return Paths(
            File(databases, MobileContractV02.DATABASE_FILENAME),
            privateDirectory(files, MobileContractV02.STAGING_DIRECTORY),
        )
    }

    private fun privateDirectory(parent: File, name: String): File {
        val directory = File(parent, name)
        try {
            Os.mkdir(directory.path, 0x1c0) // 0700
        } catch (error: ErrnoException) {
            if (error.errno != OsConstants.EEXIST) throw error
        }
        val descriptor = Os.open(
            directory.path,
            // O_DIRECTORY is not a public Android SDK constant. Nonblocking
            // open plus fstat rejects non-directories without hanging on FIFOs.
            OsConstants.O_RDONLY or OsConstants.O_NONBLOCK or
                OsConstants.O_NOFOLLOW or OsConstants.O_CLOEXEC,
            0,
        )
        try {
            val metadata = Os.fstat(descriptor)
            check(metadata.st_uid == Process.myUid() && OsConstants.S_ISDIR(metadata.st_mode)) {
                "应用私有目录所有权异常"
            }
            // Repair app-created directory modes without following a substituted link.
            Os.fchmod(descriptor, 0x1c0)
        } finally {
            Os.close(descriptor)
        }
        return directory
    }
}
