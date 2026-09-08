//! Keep SQLite's native locking, WAL and I/O, but validate canonical container
//! paths without SQLite unixFullPathname's lstat on every outside ancestor.
use rusqlite::ffi;
#[cfg(unix)]
use std::os::unix::ffi::OsStrExt;
use std::{
    ffi::CStr,
    os::raw::{c_char, c_int},
    path::Path,
    sync::OnceLock,
};

pub(super) const NAME: &str = "media-backup-container-v1";
static REGISTERED: OnceLock<Result<(), c_int>> = OnceLock::new();

pub(super) fn register() -> rusqlite::Result<()> {
    let result = REGISTERED.get_or_init(|| {
        // SAFETY: SQLite owns the built-in VFS for process lifetime. Clone its
        // immutable callbacks/app data; keep our registered object alive forever.
        unsafe {
            let original = ffi::sqlite3_vfs_find(c"unix".as_ptr());
            if original.is_null() {
                return Err(ffi::SQLITE_CANTOPEN);
            }
            let mut vfs = Box::new(*original);
            vfs.zName = c"media-backup-container-v1".as_ptr();
            vfs.pNext = std::ptr::null_mut();
            vfs.xFullPathname = Some(full_pathname);
            let pointer = Box::into_raw(vfs);
            let status = ffi::sqlite3_vfs_register(pointer, 0);
            if status == ffi::SQLITE_OK {
                Ok(())
            } else {
                drop(Box::from_raw(pointer));
                Err(status)
            }
        }
    });
    result.map_err(|code| rusqlite::Error::SqliteFailure(ffi::Error::new(code), None))
}

unsafe extern "C" fn full_pathname(
    _vfs: *mut ffi::sqlite3_vfs,
    input: *const c_char,
    size: c_int,
    output: *mut c_char,
) -> c_int {
    if input.is_null() || output.is_null() || size <= 0 {
        return ffi::SQLITE_CANTOPEN;
    }
    std::panic::catch_unwind(|| {
        // SAFETY: SQLite passes a NUL-terminated input and an output of size
        // bytes. Validate length before copying; never unwind across this ABI.
        let bytes = unsafe { CStr::from_ptr(input) }.to_bytes();
        if bytes.len() >= size as usize {
            return ffi::SQLITE_CANTOPEN;
        }
        let path = Path::new(std::ffi::OsStr::from_bytes(bytes));
        // All product connections open an already reserved 0600 regular file.
        // Reject relative paths, traversal, symlink ancestors/final components
        // and hard links rather than canonicalizing potentially hostile aliases.
        if super::require_client_database_path(path).is_err()
            || super::require_secure_database_file(path).is_err()
        {
            return ffi::SQLITE_CANTOPEN;
        }
        unsafe {
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), output.cast(), bytes.len());
            *output.add(bytes.len()) = 0;
        }
        ffi::SQLITE_OK
    })
    .unwrap_or(ffi::SQLITE_CANTOPEN)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn callback_is_bounded_and_rejects_aliases_without_writes() {
        let temporary = tempfile::tempdir().unwrap();
        let root = temporary.path().canonicalize().unwrap();
        let path = root.join("client.sqlite");
        super::super::initialize_current_database(&path).unwrap();
        let input = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
        let mut output = vec![b'!' as c_char; input.as_bytes().len() + 2];
        let before = std::fs::read(&path).unwrap();
        unsafe {
            assert_eq!(
                full_pathname(std::ptr::null_mut(), input.as_ptr(), 1, output.as_mut_ptr()),
                ffi::SQLITE_CANTOPEN
            );
            assert!(output.iter().all(|b| *b == b'!' as c_char));
            assert_eq!(
                full_pathname(
                    std::ptr::null_mut(),
                    input.as_ptr(),
                    output.len() as c_int,
                    output.as_mut_ptr()
                ),
                ffi::SQLITE_OK
            );
            assert_eq!(CStr::from_ptr(output.as_ptr()), input.as_c_str());
            assert_eq!(output[output.len() - 1], b'!' as c_char);
        }
        let alias = root.join("alias.sqlite");
        std::os::unix::fs::symlink(&path, &alias).unwrap();
        let alias = std::ffi::CString::new(alias.as_os_str().as_bytes()).unwrap();
        let mut output = vec![b'!' as c_char; 4096];
        unsafe {
            assert_eq!(
                full_pathname(
                    std::ptr::null_mut(),
                    alias.as_ptr(),
                    output.len() as c_int,
                    output.as_mut_ptr()
                ),
                ffi::SQLITE_CANTOPEN
            );
            assert_eq!(
                full_pathname(
                    std::ptr::null_mut(),
                    std::ptr::null(),
                    output.len() as c_int,
                    output.as_mut_ptr()
                ),
                ffi::SQLITE_CANTOPEN
            );
        }
        assert!(output.iter().all(|b| *b == b'!' as c_char));
        assert_eq!(std::fs::read(path).unwrap(), before);
    }
}
