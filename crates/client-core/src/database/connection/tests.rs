use super::*;

fn database() -> (tempfile::TempDir, Connection) {
    let root = tempfile::tempdir().unwrap();
    let mut connection = Connection::open(&root.path().join("worker.sqlite")).unwrap();
    connection
        .execute_batch("CREATE TABLE facts(id INTEGER PRIMARY KEY, value BLOB NOT NULL) STRICT")
        .unwrap();
    (root, connection)
}

#[test]
fn failed_transaction_rolls_back_before_a_new_transaction_or_reopen() {
    let (root, mut connection) = database();
    connection
        .execute(
            "INSERT INTO facts VALUES(?, ?)",
            params![1i64, vec![0u8, 255]],
        )
        .unwrap();
    {
        let mut transaction = connection.transaction().unwrap();
        transaction
            .execute(
                "UPDATE facts SET value=? WHERE id=?",
                params![vec![7u8], 1i64],
            )
            .unwrap();
        assert!(transaction
            .execute("INSERT INTO facts VALUES(?, ?)", params![1i64, vec![8u8]])
            .is_err());
    }
    let mut transaction = connection.transaction().unwrap();
    assert_eq!(
        transaction
            .query_row("SELECT value FROM facts WHERE id=1", params![], |row| row
                .get::<_, Vec<
                u8,
            >>(
                0
            ))
            .unwrap(),
        vec![0, 255]
    );
    transaction
        .execute("INSERT INTO facts VALUES(?, ?)", params![2i64, vec![9u8]])
        .unwrap();
    transaction.commit().unwrap();
    drop(connection);
    let mut connection = Connection::open(&root.path().join("worker.sqlite")).unwrap();
    assert_eq!(
        connection
            .query_row("SELECT count(*) FROM facts", params![], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        2
    );
}

#[test]
fn integer_overflow_is_rejected_before_writes_and_optional_keeps_errors() {
    let (_root, mut connection) = database();
    assert!(connection
        .execute(
            "INSERT INTO facts VALUES(?, ?)",
            params![u64::MAX, vec![1u8]]
        )
        .is_err());
    assert_eq!(
        connection
            .query_row("SELECT count(*) FROM facts", params![], |row| row
                .get::<_, i64>(0))
            .unwrap(),
        0
    );
    assert!(connection
        .query_row("SELECT -1", params![], |row| row.get::<_, u64>(0))
        .optional()
        .is_err());
    assert_eq!(
        connection
            .query_row("SELECT id FROM facts", params![], |row| row
                .get::<_, i64>(0))
            .optional()
            .unwrap(),
        None
    );
}

#[test]
fn a_partly_consumed_row_stream_releases_the_connection() {
    let (_root, mut connection) = database();
    connection
        .execute_batch("INSERT INTO facts VALUES(1, x'00'), (2, x'ff')")
        .unwrap();
    {
        let mut statement = connection
            .prepare("SELECT id FROM facts ORDER BY id")
            .unwrap();
        let mut rows = statement
            .query_map(params![], |row| row.get::<_, i64>(0))
            .unwrap();
        assert_eq!(rows.next().unwrap().unwrap(), 1);
    }
    assert_eq!(
        connection
            .execute("DELETE FROM facts WHERE id=2", params![])
            .unwrap(),
        1
    );
}

#[test]
fn direct_worker_operations_remain_synchronous_inside_a_tokio_runtime() {
    for runtime in [
        tokio::runtime::Builder::new_current_thread()
            .build()
            .unwrap(),
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(1)
            .build()
            .unwrap(),
    ] {
        runtime.block_on(async {
            let (_root, mut connection) = database();
            let mut transaction = connection.transaction().unwrap();
            transaction
                .execute(
                    "INSERT INTO facts VALUES(?, ?)",
                    params![1i64, vec![0u8, 255]],
                )
                .unwrap();
            transaction.commit().unwrap();
            assert_eq!(
                connection
                    .query_row("SELECT value FROM facts", params![], |row| row
                        .get::<_, Vec<u8>>(0))
                    .unwrap(),
                vec![0, 255]
            );
            drop(connection);
        });
    }
}
