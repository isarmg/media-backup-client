use super::*;
fn open(path: &Path) -> Client {
    Client::open(
        path,
        ClientConfig {
            product: MOBILE_PRODUCT.into(),
            application_version: MOBILE_APPLICATION_VERSION.into(),
            revision: MOBILE_REVISION,
            state_epoch: MOBILE_STATE_EPOCH.into(),
            part_size: 4,
        },
    )
    .unwrap()
}
fn call(client: &Client, command: Value) -> Result<Value, ClientError> {
    let request=serde_json::from_value(json!({"product":MOBILE_PRODUCT,"application_version":MOBILE_APPLICATION_VERSION,"revision":MOBILE_REVISION,"state_epoch":MOBILE_STATE_EPOCH,"command":{"op":"gallery","command":command}})).unwrap();
    client.transfer(request)
}
fn asset(id: Uuid, favorite: bool) -> Value {
    json!({"asset_id":id,"source_asset_id":"local","media_kind":"photo","source_created_at_ms":1,"favorite":favorite,"archived":false,"trashed_at_ms":null,"tag_names":[],"resources":[]})
}
fn event(sequence: i64, id: Uuid) -> Value {
    json!({"sequence":sequence,"entity_kind":"asset","entity_id":id,"operation":"upsert","changed_at_ms":1})
}
#[test]
fn snapshot_and_event_application_are_atomic_and_restartable() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("client.sqlite");
    let c = open(&path);
    let id = Uuid::new_v4();
    call(&c, json!({"op":"begin_snapshot","sequence":10})).unwrap();
    call(&c,json!({"op":"snapshot_page","cursor":null,"items":[asset(id,false)],"next_cursor":id.to_string()})).unwrap();
    drop(c);
    let c = open(&path);
    assert_eq!(
        call(&c, json!({"op":"state"})).unwrap()["snapshot_cursor"],
        id.to_string()
    );
    assert!(call(
        &c,
        json!({"op":"snapshot_page","cursor":null,"items":[],"next_cursor":null})
    )
    .is_err());
    call(
        &c,
        json!({"op":"snapshot_page","cursor":id.to_string(),"items":[],"next_cursor":null}),
    )
    .unwrap();
    call(&c,json!({"op":"save_page","query_key":"all","cursor":null,"next_cursor":null,"items":[asset(id,false)]})).unwrap();
    // A late malformed event rolls back even an earlier valid upsert and retains the cursor.
    assert!(call(&c,json!({"op":"apply_events","expected_sequence":10,"next_sequence":12,"events":[{"event":event(11,id),"asset":asset(id,true)},{"event":event(12,id),"asset":asset(Uuid::new_v4(),true)}]})).is_err());
    assert_eq!(call(&c, json!({"op":"state"})).unwrap()["sequence"], 10);
    assert_eq!(
        call(
            &c,
            json!({"op":"read_page","query_key":"all","cursor":null})
        )
        .unwrap()["items"][0]["favorite"],
        false
    );
    assert!(call(
        &c,
        json!({"op":"apply_events","expected_sequence":10,"next_sequence":12,"events":[]})
    )
    .is_err());
    call(&c,json!({"op":"apply_events","expected_sequence":10,"next_sequence":11,"events":[{"event":event(11,id),"asset":asset(id,true)}]})).unwrap();
    assert!(call(
        &c,
        json!({"op":"read_page","query_key":"all","cursor":null})
    )
    .unwrap()
    .is_null());
    call(&c,json!({"op":"apply_events","expected_sequence":11,"next_sequence":12,"events":[{"event":event(12,id),"asset":null}]})).unwrap();
    let mut conn = c.connection.lock().unwrap();
    assert_eq!(
        conn.query_row("SELECT COUNT(*) FROM gallery_assets", params![], |r| r
            .get::<_, i64>(0))
            .unwrap(),
        0
    );
}
#[test]
fn no_events_preserves_cached_pages_and_catalog_never_assumes_a_backup() {
    let root = tempfile::tempdir().unwrap();
    let c = open(&root.path().join("client.sqlite"));
    call(&c, json!({"op":"begin_snapshot","sequence":0})).unwrap();
    call(
        &c,
        json!({"op":"snapshot_page","cursor":null,"items":[],"next_cursor":null}),
    )
    .unwrap();
    call(
        &c,
        json!({"op":"save_page","query_key":"photos","cursor":null,"next_cursor":null,"items":[]}),
    )
    .unwrap();
    call(
        &c,
        json!({"op":"apply_events","expected_sequence":0,"next_sequence":0,"events":[]}),
    )
    .unwrap();
    assert!(call(
        &c,
        json!({"op":"read_page","query_key":"photos","cursor":null})
    )
    .unwrap()
    .is_object());
    call(&c, json!({"op":"begin_catalog"})).unwrap();
    call(&c,json!({"op":"catalog","items":[{"source_id":"local","name":"photo","media_kind":"photo","album_id":"album","created_ms":2,"modified_ms":1,"size":8,"descriptor":"{}"}]})).unwrap();
    call(&c, json!({"op":"finish_catalog"})).unwrap();
    let page=call(&c,json!({"op":"local_page","album":"album","media_kind":"photo","unbacked":true,"offset":0,"limit":100})).unwrap();
    assert_eq!(page[0]["backup_state"], "unknown");
    call(
        &c,
        json!({"op":"exclude","source_id":"local","excluded":true}),
    )
    .unwrap();
    assert_eq!(
        call(&c, json!({"op":"is_excluded","source_id":"local"})).unwrap(),
        true
    );
    call(&c, json!({"op":"begin_catalog"})).unwrap();
    assert_eq!(call(&c,json!({"op":"local_page","album":null,"media_kind":null,"unbacked":false,"offset":0,"limit":100})).unwrap().as_array().unwrap().len(),1);
    call(&c, json!({"op":"finish_catalog"})).unwrap();
    assert!(call(&c,json!({"op":"local_page","album":null,"media_kind":null,"unbacked":false,"offset":0,"limit":100})).unwrap().as_array().unwrap().is_empty());
}

#[test]
fn interrupted_catalog_scan_keeps_previous_page_until_finish() {
    let root = tempfile::tempdir().unwrap();
    let path = root.path().join("client.sqlite");
    let old = json!({"source_id":"old","name":"old","media_kind":"photo","album_id":"a","created_ms":1,"modified_ms":1,"size":8,"descriptor":"{}"});
    let new = json!({"source_id":"new","name":"new","media_kind":"photo","album_id":"a","created_ms":2,"modified_ms":2,"size":9,"descriptor":"{}"});
    let page = |client: &Client| {
        call(client,json!({"op":"local_page","album":null,"media_kind":null,"unbacked":false,"offset":0,"limit":100})).unwrap()
    };
    let c = open(&path);
    call(&c, json!({"op":"begin_catalog"})).unwrap();
    call(&c, json!({"op":"catalog","items":[old]})).unwrap();
    assert!(page(&c).as_array().unwrap().is_empty());
    call(&c, json!({"op":"finish_catalog"})).unwrap();
    assert_eq!(page(&c)[0]["source_id"], "old");
    call(&c, json!({"op":"begin_catalog"})).unwrap();
    call(&c, json!({"op":"catalog","items":[new]})).unwrap();
    assert_eq!(page(&c).as_array().unwrap().len(), 1);
    assert_eq!(page(&c)[0]["source_id"], "old");
    drop(c);
    let c = open(&path);
    call(&c, json!({"op":"begin_catalog"})).unwrap();
    assert_eq!(page(&c).as_array().unwrap().len(), 1);
    call(&c, json!({"op":"catalog","items":[new]})).unwrap();
    call(&c, json!({"op":"finish_catalog"})).unwrap();
    assert_eq!(page(&c).as_array().unwrap().len(), 1);
    assert_eq!(page(&c)[0]["source_id"], "new");
}
