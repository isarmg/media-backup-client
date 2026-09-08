use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    path::{Component, Path, PathBuf},
    time::Duration,
};

use anyhow::{ensure, Context};
use rusqlite::{params, Connection, OpenFlags};
use sha2::{Digest, Sha256};

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

#[cfg(any(target_vendor = "apple", all(test, unix)))]
mod sandbox_vfs;

const APPLICATION: &str = "media-backup-client";
const BUSY_TIMEOUT: Duration = Duration::from_secs(5);
const CURRENT_SCHEMA: &str = include_str!("current_schema.sql");
pub(super) const CURRENT_SCHEMA_REVISION: i64 = 2;
pub(super) const CURRENT_SCHEMA_SHA256: &str =
    "87eb55ba9366cd06d5a2e0b69b5fd4c7a6eef59c381e9fd4ea340e9e04ef6dfb";
const PRODUCT_METADATA_SQL: &str = "CREATE TABLE product_metadata (
    singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
    application TEXT NOT NULL,
    application_version TEXT NOT NULL,
    schema_revision INTEGER NOT NULL,
    schema_sha256 TEXT NOT NULL
)";

#[derive(Debug, thiserror::Error)]
pub(super) enum OpenStage {
    #[error("MBDB-PATH：无法访问备份目录")]
    Path,
    #[error("MBDB-CREATE：无法创建备份数据库")]
    Create,
    #[error("MBDB-VALIDATE：本地备份数据库校验失败")]
    Validate,
    #[error("MBDB-CONNECT：无法连接本地备份数据库")]
    Connect,
    #[error("MBDB-CONFIGURE：无法启用数据库写入")]
    Configure,
}
impl OpenStage {
    pub(super) fn public_message(&self) -> &'static str {
        match self {
            Self::Path => "MBDB-PATH：无法访问备份目录",
            Self::Create => "MBDB-CREATE：无法创建备份数据库",
            Self::Validate => "MBDB-VALIDATE：本地备份数据库校验失败",
            Self::Connect => "MBDB-CONNECT：无法连接本地备份数据库",
            Self::Configure => "MBDB-CONFIGURE：无法启用数据库写入",
        }
    }
}

pub(super) fn open_current(path: &Path) -> anyhow::Result<Connection> {
    require_client_database_path(path)?;
    require_real_parent(path).context(OpenStage::Path)?;
    match fs::symlink_metadata(path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            require_absent_sidecars(path).context(OpenStage::Validate)?;
            initialize_current_database(path).context(OpenStage::Create)?;
        }
        Err(error) => return Err(anyhow::Error::from(error).context(OpenStage::Path)),
        Ok(_) => validate_current_database(path).context(OpenStage::Validate)?,
    }

    require_secure_database_file(path).context(OpenStage::Validate)?;
    let connection = open_sqlite(
        path,
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )
    .context(OpenStage::Connect)?;
    connection.busy_timeout(BUSY_TIMEOUT)?;
    // Validate the production generation again before the first intentional
    // write. The private snapshot above guarantees an invalid existing
    // generation is rejected without touching its main file or sidecars.
    validate_current_connection(&connection).context(OpenStage::Validate)?;
    connection
        .pragma_update(None, "foreign_keys", "ON")
        .context(OpenStage::Configure)?;
    connection
        .pragma_update(None, "journal_mode", "WAL")
        .context(OpenStage::Configure)?;
    connection
        .pragma_update(None, "synchronous", "FULL")
        .context(OpenStage::Configure)?;
    Ok(connection)
}

fn open_sqlite(path: &Path, flags: OpenFlags) -> rusqlite::Result<Connection> {
    #[cfg(any(target_vendor = "apple", all(test, unix)))]
    {
        sandbox_vfs::register()?;
        Connection::open_with_flags_and_vfs(path, flags, sandbox_vfs::NAME)
    }
    #[cfg(not(any(target_vendor = "apple", all(test, unix))))]
    Connection::open_with_flags(path, flags)
}

fn require_client_database_path(path: &Path) -> anyhow::Result<()> {
    ensure!(path.is_absolute(), "client SQLite path must be absolute");
    ensure!(
        path.file_name().is_some(),
        "client SQLite path must name a file"
    );
    ensure!(
        !path
            .components()
            .any(|component| matches!(component, Component::ParentDir)),
        "client SQLite path must not contain parent traversal"
    );
    Ok(())
}

fn validate_current_database(path: &Path) -> anyhow::Result<()> {
    require_secure_database_file(path)?;
    let snapshot = snapshot_generation(path)?;
    let connection = open_sqlite(
        &snapshot.database,
        OpenFlags::SQLITE_OPEN_READ_WRITE
            | OpenFlags::SQLITE_OPEN_NO_MUTEX
            | OpenFlags::SQLITE_OPEN_NOFOLLOW,
    )
    .context("open private client SQLite current-schema snapshot")?;
    connection.busy_timeout(BUSY_TIMEOUT)?;
    validate_current_connection(&connection)
}

struct ValidationSnapshot {
    _directory: tempfile::TempDir,
    database: PathBuf,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct SourceSnapshot {
    hash: [u8; 32],
    length: u64,
    #[cfg(unix)]
    device: u64,
    #[cfg(unix)]
    inode: u64,
}

#[derive(Debug, thiserror::Error)]
#[error("client SQLite generation changed during current-schema validation")]
struct GenerationChanged;

fn snapshot_generation(path: &Path) -> anyhow::Result<ValidationSnapshot> {
    let mut last_change = None;
    for _ in 0..4 {
        match snapshot_generation_once(path) {
            Ok(snapshot) => return Ok(snapshot),
            Err(error) if error.is::<GenerationChanged>() => {
                last_change = Some(error);
                std::thread::yield_now();
            }
            Err(error) => return Err(error),
        }
    }
    Err(last_change.unwrap_or_else(|| anyhow::anyhow!(GenerationChanged)))
}

fn snapshot_generation_once(path: &Path) -> anyhow::Result<ValidationSnapshot> {
    let parent = path
        .parent()
        .context("client SQLite path must have a parent")?;
    let directory = tempfile::Builder::new()
        .prefix("media-client-schema-check-")
        .tempdir_in(parent)
        .context("create private client current-schema validation directory")?;
    let database = directory.path().join("database.sqlite3");
    let sources = [
        path.to_path_buf(),
        sqlite_sidecar(path, "-wal"),
        sqlite_sidecar(path, "-journal"),
    ];
    let destinations = [
        database.clone(),
        sqlite_sidecar(&database, "-wal"),
        sqlite_sidecar(&database, "-journal"),
    ];

    // A SQLite read-only connection to a WAL generation still writes lock
    // bytes to `-shm`. Replay a private copy so rejecting a foreign, empty, or
    // drifted database leaves the entire source generation byte-identical.
    let mut expected = Vec::with_capacity(sources.len());
    for (source, destination) in sources.iter().zip(&destinations) {
        expected.push(copy_generation_file(source, destination)?);
    }
    let _ = source_snapshot(&sqlite_sidecar(path, "-shm"))?;
    for (source, expected) in sources.iter().zip(expected) {
        if source_snapshot(source)? != expected {
            return Err(GenerationChanged.into());
        }
    }

    Ok(ValidationSnapshot {
        _directory: directory,
        database,
    })
}

fn copy_generation_file(
    source_path: &Path,
    destination_path: &Path,
) -> anyhow::Result<Option<SourceSnapshot>> {
    let Some((mut source, before)) = open_source_snapshot(source_path)? else {
        return Ok(None);
    };
    let mut options = OpenOptions::new();
    options.read(true).write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    let mut destination = options.open(destination_path)?;
    std::io::copy(&mut source, &mut destination)?;
    destination.flush()?;
    destination.sync_all()?;
    destination.seek(SeekFrom::Start(0))?;
    let copied_hash = hash_reader(&mut destination)?;
    let Some(after) = source_snapshot(source_path)? else {
        return Err(GenerationChanged.into());
    };
    if before != after || copied_hash != after.hash {
        return Err(GenerationChanged.into());
    }
    Ok(Some(after))
}

fn source_snapshot(path: &Path) -> anyhow::Result<Option<SourceSnapshot>> {
    let Some((_, snapshot)) = open_source_snapshot(path)? else {
        return Ok(None);
    };
    Ok(Some(snapshot))
}

fn open_source_snapshot(path: &Path) -> anyhow::Result<Option<(File, SourceSnapshot)>> {
    let initial = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    ensure!(
        initial.is_file() && !initial.file_type().is_symlink(),
        "client SQLite generation must contain only regular files without symbolic links"
    );
    #[cfg(unix)]
    ensure!(
        initial.nlink() == 1,
        "client SQLite generation files must not have hard-link aliases"
    );
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    let mut file = match options.open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let opened = file.metadata()?;
    let named = fs::symlink_metadata(path)?;
    ensure!(
        opened.is_file() && named.is_file() && !named.file_type().is_symlink(),
        "client SQLite generation must contain only regular files without symbolic links"
    );
    #[cfg(unix)]
    ensure!(
        opened.nlink() == 1
            && named.nlink() == 1
            && opened.dev() == named.dev()
            && opened.ino() == named.ino(),
        "client SQLite generation files must not have hard-link aliases or change while opened"
    );
    let hash = hash_reader(&mut file)?;
    file.seek(SeekFrom::Start(0))?;
    Ok(Some((
        file,
        SourceSnapshot {
            hash,
            length: opened.len(),
            #[cfg(unix)]
            device: opened.dev(),
            #[cfg(unix)]
            inode: opened.ino(),
        },
    )))
}

fn hash_reader(reader: &mut impl Read) -> anyhow::Result<[u8; 32]> {
    let mut hasher = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher.finalize().into())
}

fn initialize_current_database(path: &Path) -> anyhow::Result<()> {
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    let reserved = options
        .open(path)
        .with_context(|| format!("create current client SQLite database {}", path.display()))?;
    reserved.sync_all()?;
    drop(reserved);

    let result = (|| {
        let connection = open_sqlite(
            path,
            OpenFlags::SQLITE_OPEN_READ_WRITE
                | OpenFlags::SQLITE_OPEN_NO_MUTEX
                | OpenFlags::SQLITE_OPEN_NOFOLLOW,
        )?;
        connection.busy_timeout(BUSY_TIMEOUT)?;
        connection.execute_batch("PRAGMA foreign_keys=ON; BEGIN IMMEDIATE;")?;
        let transaction_result = (|| {
            connection.execute_batch(CURRENT_SCHEMA)?;
            let actual = schema_fingerprint(&connection)?;
            ensure!(
                actual == CURRENT_SCHEMA_SHA256,
                "compiled current client schema fingerprint mismatch: {actual}"
            );
            connection.execute(
                "INSERT INTO product_metadata (
                     singleton, application, application_version, schema_revision, schema_sha256
                 ) VALUES (1, ?, ?, ?, ?)",
                params![
                    APPLICATION,
                    env!("CARGO_PKG_VERSION"),
                    CURRENT_SCHEMA_REVISION,
                    CURRENT_SCHEMA_SHA256
                ],
            )?;
            validate_current_connection(&connection)
        })();
        match transaction_result {
            Ok(()) => connection.execute_batch("COMMIT")?,
            Err(error) => {
                let _ = connection.execute_batch("ROLLBACK");
                return Err(error);
            }
        }
        drop(connection);
        File::open(path)?.sync_all()?;
        sync_parent(path)?;
        Ok(())
    })();

    if result.is_err() {
        for candidate in sqlite_generation_paths(path) {
            let _ = fs::remove_file(candidate);
        }
        let _ = sync_parent(path);
    }
    result
}

fn require_absent_sidecars(path: &Path) -> anyhow::Result<()> {
    for candidate in sqlite_generation_paths(path).into_iter().skip(1) {
        match fs::symlink_metadata(&candidate) {
            Ok(_) => anyhow::bail!(
                "client SQLite main file is absent but its generation contains a sidecar"
            ),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(())
}

fn validate_current_connection(connection: &Connection) -> anyhow::Result<()> {
    validate_product_metadata_table(connection)?;
    let count: i64 = connection.query_row("SELECT COUNT(*) FROM product_metadata", [], |row| {
        row.get(0)
    })?;
    ensure!(count == 1, "product_metadata must contain exactly one row");
    let (singleton, application, version, revision, expected_fingerprint): (
        i64,
        String,
        String,
        i64,
        String,
    ) = connection.query_row(
        "SELECT singleton, application, application_version, schema_revision, schema_sha256
         FROM product_metadata",
        [],
        |row| {
            Ok((
                row.get(0)?,
                row.get(1)?,
                row.get(2)?,
                row.get(3)?,
                row.get(4)?,
            ))
        },
    )?;
    ensure!(singleton == 1, "product_metadata singleton is invalid");
    ensure!(
        application == APPLICATION,
        "client database belongs to a different application"
    );
    ensure!(
        version == env!("CARGO_PKG_VERSION"),
        "client database application version is not exactly current"
    );
    ensure!(
        revision == CURRENT_SCHEMA_REVISION,
        "client database schema revision is not exactly current"
    );
    ensure!(
        expected_fingerprint == CURRENT_SCHEMA_SHA256,
        "client database schema fingerprint metadata is not exactly current"
    );
    let actual = schema_fingerprint(connection)?;
    ensure!(
        actual == CURRENT_SCHEMA_SHA256,
        "actual client SQLite schema does not match the compiled current schema"
    );
    let integrity: String = connection.query_row("PRAGMA integrity_check", [], |row| row.get(0))?;
    ensure!(
        integrity.eq_ignore_ascii_case("ok"),
        "client SQLite integrity check failed"
    );
    let mut foreign_keys = connection.prepare("PRAGMA foreign_key_check")?;
    ensure!(
        foreign_keys.query([])?.next()?.is_none(),
        "client SQLite foreign-key check failed"
    );
    Ok(())
}

fn validate_product_metadata_table(connection: &Connection) -> anyhow::Result<()> {
    let sql: String = connection
        .query_row(
            "SELECT sql FROM sqlite_schema
             WHERE type = 'table' AND name = 'product_metadata'",
            [],
            |row| row.get(0),
        )
        .context("client database has no current product_metadata table")?;
    ensure!(
        normalize_sql(&sql) == normalize_sql(PRODUCT_METADATA_SQL),
        "client product_metadata table does not match the current contract"
    );
    let mut columns = connection.prepare("PRAGMA table_info('product_metadata')")?;
    let actual = columns
        .query_map([], |row| {
            Ok((
                row.get::<_, String>(1)?,
                row.get::<_, String>(2)?,
                row.get::<_, i64>(3)?,
                row.get::<_, i64>(5)?,
            ))
        })?
        .collect::<Result<Vec<_>, _>>()?;
    let expected = vec![
        ("singleton".to_string(), "INTEGER".to_string(), 1, 1),
        ("application".to_string(), "TEXT".to_string(), 1, 0),
        ("application_version".to_string(), "TEXT".to_string(), 1, 0),
        ("schema_revision".to_string(), "INTEGER".to_string(), 1, 0),
        ("schema_sha256".to_string(), "TEXT".to_string(), 1, 0),
    ];
    ensure!(
        actual == expected,
        "client product_metadata columns do not match the current contract"
    );
    Ok(())
}

fn schema_fingerprint(connection: &Connection) -> anyhow::Result<String> {
    let mut statement = connection.prepare(
        "SELECT type, name, tbl_name, COALESCE(sql, '')
         FROM sqlite_schema
         WHERE name NOT GLOB 'sqlite_*' AND name <> 'product_metadata'
         ORDER BY type, name, tbl_name",
    )?;
    let rows = statement.query_map([], |row| {
        Ok([
            row.get::<_, String>(0)?,
            row.get::<_, String>(1)?,
            row.get::<_, String>(2)?,
            row.get::<_, String>(3)?,
        ])
    })?;
    let mut hasher = Sha256::new();
    for row in rows {
        for field in row? {
            let bytes = field.as_bytes();
            let length = u64::try_from(bytes.len()).context("schema field is too large")?;
            hasher.update(length.to_be_bytes());
            hasher.update(bytes);
        }
    }
    Ok(lower_hex(hasher.finalize()))
}

fn normalize_sql(value: &str) -> String {
    value
        .chars()
        .filter(|character| !character.is_ascii_whitespace())
        .flat_map(char::to_lowercase)
        .collect()
}

fn lower_hex(bytes: impl AsRef<[u8]>) -> String {
    use std::fmt::Write as _;
    let mut output = String::with_capacity(bytes.as_ref().len() * 2);
    for byte in bytes.as_ref() {
        let _ = write!(&mut output, "{byte:02x}");
    }
    output
}

fn require_secure_database_file(path: &Path) -> anyhow::Result<()> {
    require_real_parent(path)?;
    let metadata = fs::symlink_metadata(path)
        .with_context(|| format!("client SQLite database does not exist: {}", path.display()))?;
    ensure!(
        metadata.is_file() && !metadata.file_type().is_symlink(),
        "client SQLite database must be a regular file without symbolic links"
    );
    #[cfg(unix)]
    ensure!(
        metadata.nlink() == 1,
        "client SQLite database must not have hard-link aliases"
    );
    #[cfg(unix)]
    ensure!(
        metadata.permissions().mode() & 0o077 == 0,
        "client SQLite database permissions must not grant group or other access"
    );
    Ok(())
}

fn require_real_parent(path: &Path) -> anyhow::Result<()> {
    let parent = path
        .parent()
        .context("client SQLite path must have a parent")?;
    #[cfg(unix)]
    sarmg_client_fs_safety::validate_directory_path(parent)?;
    #[cfg(not(unix))]
    {
        let mut current = PathBuf::new();
        for component in parent.components() {
            current.push(component);
            let metadata = fs::symlink_metadata(&current)?;
            ensure!(
                metadata.is_dir() && !metadata.file_type().is_symlink(),
                "client SQLite path must not traverse symbolic links or special files"
            );
        }
    }
    Ok(())
}

fn sqlite_generation_paths(path: &Path) -> [PathBuf; 4] {
    [
        path.to_path_buf(),
        sqlite_sidecar(path, "-wal"),
        sqlite_sidecar(path, "-shm"),
        sqlite_sidecar(path, "-journal"),
    ]
}

fn sqlite_sidecar(path: &Path, suffix: &str) -> PathBuf {
    let mut value = path.as_os_str().to_os_string();
    value.push(suffix);
    PathBuf::from(value)
}

fn sync_parent(path: &Path) -> anyhow::Result<()> {
    #[cfg(unix)]
    File::open(path.parent().unwrap_or_else(|| Path::new(".")))?.sync_all()?;
    Ok(())
}

#[cfg(test)]
pub(crate) mod tests_support {
    use super::*;

    #[test]
    fn validation_snapshot_stays_in_database_sandbox() -> anyhow::Result<()> {
        let root = tempfile::tempdir()?;
        let root_path = root.path().canonicalize()?;
        let path = root_path.join("client.sqlite");
        initialize_current_database(&path)?;
        let snapshot = snapshot_generation(&path)?;
        assert_eq!(
            snapshot._directory.path().parent(),
            Some(root_path.as_path())
        );
        let snapshot_path = snapshot._directory.path().to_path_buf();
        drop(snapshot);
        assert!(!snapshot_path.exists());
        Ok(())
    }

    pub(crate) const APPLICATION: &str = super::APPLICATION;

    pub(crate) fn initialize(path: &Path) -> anyhow::Result<()> {
        initialize_current_database(path)
    }

    pub(crate) fn fingerprint(connection: &Connection) -> anyhow::Result<String> {
        schema_fingerprint(connection)
    }

    pub(crate) fn generation_paths(path: &Path) -> [PathBuf; 4] {
        sqlite_generation_paths(path)
    }
}
