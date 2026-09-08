use super::*;
use serde_json::{json, Value};

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TransferRequest {
    pub product: String,
    pub application_version: String,
    pub revision: u32,
    pub state_epoch: String,
    pub command: TransferCommand,
}

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum TransferCommand {
    Gallery {
        command: crate::GalleryCommand,
    },
    CreateBatch {
        id: String,
        items: Vec<BatchItem>,
    },
    Items {
        batch_id: String,
    },
    Batches {},
    Bind {
        server: String,
        account_id: String,
        device_id: String,
    },
    SetSource {
        batch_id: String,
        item_id: String,
        source: String,
    },
    SetItem {
        batch_id: String,
        item_id: String,
        state: String,
        error: Option<String>,
    },
    CancelBatch {
        batch_id: String,
    },
    RetryBatch {
        batch_id: String,
    },
    Receipt {
        job_id: String,
        asset_id: String,
        resource_id: String,
        content_blake3: String,
    },
    Alias {
        alias: String,
        source_id: String,
    },
    LinkResource {
        batch_id: String,
        item_id: String,
        asset: String,
        resource: String,
        modified_ms: i64,
    },
    Active {
        job_id: String,
    },
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BatchItem {
    pub id: String,
    /// Platform-owned, durable read descriptor. Never passed to the file preparer as a path.
    pub source: String,
}

impl Client {
    pub fn transfer(&self, request: TransferRequest) -> Result<Value, ClientError> {
        validate_contract(
            &request.product,
            &request.application_version,
            request.revision,
            &request.state_epoch,
        )?;
        if let TransferCommand::Gallery { command } = request.command {
            return self.gallery(command);
        }
        let mut connection = self.connection.lock().unwrap_or_else(|p| p.into_inner());
        let tx = connection.transaction()?;
        let result = match request.command {
            TransferCommand::Gallery { .. } => unreachable!(),
            TransferCommand::Bind {
                server,
                account_id,
                device_id,
            } => {
                if !server.starts_with("https://")
                    || Uuid::parse_str(&account_id).is_err()
                    || Uuid::parse_str(&device_id).is_err()
                {
                    return Err(ClientError::InvalidContract(
                        "invalid backup account identity".into(),
                    ));
                }
                let existing: Option<(String, String)> = tx
                    .query_row(
                        "SELECT server,account_id FROM profile_binding WHERE singleton=1",
                        [],
                        |r| Ok((r.get(0)?, r.get(1)?)),
                    )
                    .optional()?;
                if existing.is_some_and(|value| value != (server.clone(), account_id.clone())) {
                    return Err(ClientError::InvalidContract(
                        "this queue belongs to a different server or account".into(),
                    ));
                }
                tx.execute("INSERT INTO profile_binding(singleton,server,account_id,device_id) VALUES (1,?1,?2,?3) ON CONFLICT(singleton) DO UPDATE SET device_id=excluded.device_id", params![server,account_id,device_id])?;
                Value::Null
            }
            TransferCommand::CreateBatch { id, items } => {
                if items.is_empty() || items.len() > 1000 || Uuid::parse_str(&id).is_err() {
                    return Err(ClientError::InvalidContract(
                        "batch requires a UUID and 1..1000 items".into(),
                    ));
                }
                tx.execute(
                    "INSERT INTO backup_batches(id, created_at_ms) VALUES (?1, ?2)",
                    params![id, now_ms()],
                )?;
                for item in items {
                    tx.execute("INSERT INTO backup_batch_items(batch_id, id, source, state) VALUES (?1, ?2, ?3, 'pending')",
                        params![id, item.id, item.source])?;
                }
                json!(id)
            }
            TransferCommand::Items { batch_id } => {
                let mut q = tx.prepare("SELECT i.id, i.source, i.state, i.error,
                    (SELECT COUNT(*) FROM batch_jobs r WHERE r.batch_id=i.batch_id AND r.item_id=i.id),
                    (SELECT COUNT(*) FROM batch_jobs r JOIN jobs j ON j.id=r.job_id WHERE r.batch_id=i.batch_id AND r.item_id=i.id AND j.state='complete'),
                    (SELECT COUNT(*) FROM batch_jobs r JOIN jobs j ON j.id=r.job_id WHERE r.batch_id=i.batch_id AND r.item_id=i.id AND j.role!='thumbnail' AND j.state='complete'),
                    (SELECT j.error FROM batch_jobs r JOIN jobs j ON j.id=r.job_id WHERE r.batch_id=i.batch_id AND r.item_id=i.id AND j.error IS NOT NULL LIMIT 1),
                    COALESCE((SELECT MAX(s.originals) FROM batch_jobs r JOIN jobs j ON j.id=r.job_id JOIN source_resource_sets s ON s.source_id=j.source_asset_id AND s.modified_ms=j.modified_ms WHERE r.batch_id=i.batch_id AND r.item_id=i.id),0)
                    FROM backup_batch_items i JOIN backup_batches b ON b.id=i.batch_id WHERE i.batch_id=?1 AND b.cancelled=0 ORDER BY i.rowid")?;
                let values = q.query_map(params![batch_id], |r| Ok(json!({
                    "id": r.get::<_,String>(0)?, "source": r.get::<_,String>(1)?,
                    "state": r.get::<_,String>(2)?, "error": r.get::<_,Option<String>>(3)?,
                    "resources": r.get::<_,u64>(4)?, "complete": r.get::<_,u64>(5)?,
                    "originals_complete": r.get::<_,u64>(6)?, "upload_error": r.get::<_,Option<String>>(7)?, "originals_expected": r.get::<_,u64>(8)?
                })))?.collect::<Result<Vec<_>, _>>()?;
                json!(values)
            }
            TransferCommand::SetSource {
                batch_id,
                item_id,
                source,
            } => {
                tx.execute("UPDATE backup_batch_items SET source=?3,state='pending',error=NULL WHERE batch_id=?1 AND id=?2", params![batch_id,item_id,source])?;
                Value::Null
            }
            TransferCommand::Batches {} => {
                let mut q = tx.prepare("SELECT b.id, b.created_at_ms, b.cancelled,
                    (SELECT COUNT(*) FROM backup_batch_items i WHERE i.batch_id=b.id),
                    (SELECT COUNT(*) FROM backup_batch_items i WHERE i.batch_id=b.id AND i.state='queued'
                       AND EXISTS(SELECT 1 FROM batch_jobs r WHERE r.batch_id=i.batch_id AND r.item_id=i.id)
                       AND NOT EXISTS(SELECT 1 FROM batch_jobs r JOIN jobs j ON j.id=r.job_id WHERE r.batch_id=i.batch_id AND r.item_id=i.id AND j.state!='complete'))
                    FROM backup_batches b ORDER BY created_at_ms DESC LIMIT 1000")?;
                let values = q
                    .query_map([], |r| {
                        Ok(json!({"id": r.get::<_,String>(0)?,
                    "created_at_ms": r.get::<_,i64>(1)?, "cancelled": r.get::<_,bool>(2)?,
                    "items": r.get::<_,u64>(3)?, "complete": r.get::<_,u64>(4)?}))
                    })?
                    .collect::<Result<Vec<_>, _>>()?;
                json!(values)
            }
            TransferCommand::SetItem {
                batch_id,
                item_id,
                state,
                error,
            } => {
                if !["pending", "queued", "blocked"].contains(&state.as_str()) {
                    return Err(ClientError::InvalidContract(
                        "invalid batch item state".into(),
                    ));
                }
                tx.execute(
                    "UPDATE backup_batch_items SET state=?3,error=?4 WHERE batch_id=?1 AND id=?2",
                    params![batch_id, item_id, state, error],
                )?;
                Value::Null
            }
            TransferCommand::CancelBatch { batch_id } => {
                tx.execute(
                    "UPDATE backup_batches SET cancelled=1 WHERE id=?1",
                    params![batch_id],
                )?;
                Value::Null
            }
            TransferCommand::RetryBatch { batch_id } => {
                tx.execute(
                    "UPDATE backup_batches SET cancelled=0 WHERE id=?1",
                    params![batch_id],
                )?;
                tx.execute("UPDATE backup_batch_items SET state='pending',error=NULL WHERE batch_id=?1 AND state='blocked'", params![batch_id])?;
                tx.execute("UPDATE jobs SET state=CASE WHEN prepared_json IS NULL THEN 'discovered' ELSE 'ready' END, next_retry_ms=0,error=NULL
                    WHERE state IN ('failed','retry_wait') AND id IN (SELECT job_id FROM batch_jobs WHERE batch_id=?1)", params![batch_id])?;
                Value::Null
            }
            TransferCommand::Receipt {
                job_id,
                asset_id,
                resource_id,
                content_blake3,
            } => {
                if Uuid::parse_str(&asset_id).is_err() || Uuid::parse_str(&resource_id).is_err() {
                    return Err(ClientError::InvalidContract(
                        "receipt IDs must be UUIDs".into(),
                    ));
                }
                let prepared: String = tx.query_row(
                    "SELECT prepared_json FROM jobs WHERE id=?1",
                    params![job_id],
                    |r| r.get(0),
                )?;
                let prepared: PreparedJob = serde_json::from_str(&prepared)?;
                if prepared.request.content_blake3 != content_blake3 {
                    return Err(ClientError::InvalidContract(
                        "receipt hash does not match prepared content".into(),
                    ));
                }
                tx.execute("INSERT INTO backup_receipts(job_id,asset_id,resource_id,content_blake3,confirmed_at_ms,server,account_id,device_id) VALUES (?1,?2,?3,?4,?5,(SELECT server FROM profile_binding),(SELECT account_id FROM profile_binding),(SELECT device_id FROM profile_binding))
                    ON CONFLICT(job_id) DO UPDATE SET asset_id=excluded.asset_id,resource_id=excluded.resource_id,confirmed_at_ms=excluded.confirmed_at_ms",
                    params![job_id,asset_id,resource_id,content_blake3,now_ms()])?;
                // Save receipt and completion atomically. File cleanup can safely run afterwards.
                tx.execute(
                    "UPDATE jobs SET state='complete',error=NULL,updated_at_ms=?2 WHERE id=?1",
                    params![job_id, now_ms()],
                )?;
                Value::Null
            }
            TransferCommand::Alias { alias, source_id } => {
                tx.execute(
                    "INSERT OR IGNORE INTO source_aliases(alias,source_id) VALUES (?1,?2)",
                    params![alias, source_id],
                )?;
                let canonical: String = tx.query_row(
                    "SELECT source_id FROM source_aliases WHERE alias=?1",
                    params![alias],
                    |r| r.get(0),
                )?;
                json!(canonical)
            }
            TransferCommand::LinkResource {
                batch_id,
                item_id,
                asset,
                resource,
                modified_ms,
            } => {
                let id: Option<String> = tx.query_row("SELECT id FROM jobs WHERE source_asset_id=?1 AND source_resource_id=?2 AND modified_ms=?3 ORDER BY updated_at_ms DESC LIMIT 1", params![asset,resource,modified_ms], |r| r.get(0)).optional()?;
                if let Some(id) = &id {
                    tx.execute("INSERT OR IGNORE INTO batch_jobs(batch_id,item_id,job_id) VALUES (?1,?2,?3)", params![batch_id,item_id,id])?;
                }
                json!(id.is_some())
            }
            TransferCommand::Active { job_id } => {
                let active: bool = tx.query_row("SELECT automatic=1 OR EXISTS(SELECT 1 FROM batch_jobs r JOIN backup_batches b ON b.id=r.batch_id WHERE r.job_id=jobs.id AND b.cancelled=0) FROM jobs WHERE id=?1", params![job_id], |r| r.get(0))?;
                json!(active)
            }
        };
        tx.commit()?;
        Ok(result)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn request(command: Value) -> TransferRequest {
        serde_json::from_value(json!({"product": MOBILE_PRODUCT,
            "application_version": MOBILE_APPLICATION_VERSION, "revision": MOBILE_REVISION,
            "state_epoch": MOBILE_STATE_EPOCH, "command": command}))
        .unwrap()
    }
    fn config() -> ClientConfig {
        ClientConfig {
            product: MOBILE_PRODUCT.into(),
            application_version: MOBILE_APPLICATION_VERSION.into(),
            revision: MOBILE_REVISION,
            state_epoch: MOBILE_STATE_EPOCH.into(),
            part_size: 4,
        }
    }
    fn batch(client: &Client) -> String {
        let id = Uuid::new_v4().to_string();
        client.transfer(request(json!({"op":"create_batch","id":id,"items":[{"id":"selected","source":"content://picked/1"}]}))).unwrap();
        id
    }
    fn resource(path: &Path, batch: Option<&str>) -> EnqueueResource {
        EnqueueResource {
            product: MOBILE_PRODUCT.into(),
            application_version: MOBILE_APPLICATION_VERSION.into(),
            revision: MOBILE_REVISION,
            state_epoch: MOBILE_STATE_EPOCH.into(),
            source_asset_id: "asset".into(),
            source_resource_id: "original".into(),
            media_kind: "photo".into(),
            role: "primary".into(),
            file_path: path.to_string_lossy().into(),
            filename: "photo.jpg".into(),
            mime_type: "image/jpeg".into(),
            source_created_at_ms: 1,
            modified_ms: 1,
            source_size: 8,
            metadata_json: None,
            remove_source_after_prepare: false,
            batch_id: batch.map(str::to_string),
            batch_item_id: batch.map(|_| "selected".into()),
        }
    }
    #[test]
    fn repeat_selection_preserves_upload_and_parts_across_restart() {
        let root = tempfile::tempdir().unwrap();
        let db = root.path().join("client.sqlite");
        let source = root.path().join("photo.jpg");
        fs::write(&source, b"12345678").unwrap();
        let staging = root.path().join(MOBILE_STAGING_DIRECTORY);
        let client = Client::open(&db, config()).unwrap();
        let first = batch(&client);
        let input = resource(&source, Some(&first));
        let id = client.enqueue(input.clone()).unwrap();
        let prepared = client.next_prepared(&staging).unwrap().unwrap();
        client.mark_upload(&id, "upload-1").unwrap();
        client.mark_part_uploaded(&id, 0).unwrap();
        assert!(!client.needs_resource("asset", "original", 1).unwrap());
        assert_eq!(client.enqueue(input).unwrap(), id);
        let second = batch(&client);
        assert_eq!(
            client.enqueue(resource(&source, Some(&second))).unwrap(),
            id
        );
        let c = client.connection.lock().unwrap();
        let row: (String, String, i64) = c
            .query_row(
                "SELECT state,upload_id,(SELECT COUNT(*) FROM job_parts) FROM jobs WHERE id=?1",
                [&id],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .unwrap();
        assert_eq!(row, ("uploading".into(), "upload-1".into(), 1));
        drop(c);
        drop(client);
        let client = Client::open(&db, config()).unwrap();
        let recovered = client.next_prepared(&staging).unwrap().unwrap();
        assert_eq!(recovered.generation_id, prepared.generation_id);
        assert!(recovered
            .local_parts
            .iter()
            .all(|p| Path::new(&p.path).exists()));
        assert_eq!(
            client
                .transfer(request(json!({"op":"batches"})))
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            2
        );
    }
    #[test]
    fn cancellation_only_removes_one_reference_and_automatic_work_survives() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("photo");
        fs::write(&source, b"12345678").unwrap();
        let client = Client::open(root.path().join("client.sqlite"), config()).unwrap();
        let a = batch(&client);
        let b = batch(&client);
        let id = client.enqueue(resource(&source, Some(&a))).unwrap();
        assert_eq!(id, client.enqueue(resource(&source, Some(&b))).unwrap());
        let active = || {
            client
                .transfer(request(json!({"op":"active","job_id":id})))
                .unwrap()
        };
        client
            .transfer(request(json!({"op":"cancel_batch","batch_id":a})))
            .unwrap();
        assert_eq!(active(), json!(true));
        client
            .transfer(request(json!({"op":"cancel_batch","batch_id":b})))
            .unwrap();
        assert_eq!(active(), json!(false));
        assert!(client
            .next_prepared(root.path().join(MOBILE_STAGING_DIRECTORY))
            .unwrap()
            .is_none());
        client.enqueue(resource(&source, None)).unwrap();
        assert_eq!(active(), json!(true));
    }
    #[test]
    fn retry_reuses_prepared_parts_even_after_private_source_is_removed() {
        let root = tempfile::tempdir().unwrap();
        let staging = root.path().join(MOBILE_STAGING_DIRECTORY);
        PrivateDirectory::create(&staging).unwrap();
        fs::create_dir_all(staging.join("sources")).unwrap();
        let source = staging.join("sources/photo");
        fs::write(&source, b"12345678").unwrap();
        let client = Client::open(root.path().join("client.sqlite"), config()).unwrap();
        let b = batch(&client);
        let mut input = resource(&source, Some(&b));
        input.remove_source_after_prepare = true;
        let id = client.enqueue(input).unwrap();
        let first = client.next_prepared(&staging).unwrap().unwrap();
        assert!(!source.exists());
        client
            .mark_failed(&id, "network interrupted", true)
            .unwrap();
        client
            .transfer(request(json!({"op":"retry_batch","batch_id":b})))
            .unwrap();
        let next = client.next_prepared(&staging).unwrap().unwrap();
        assert_eq!(first.generation_id, next.generation_id);
    }
    #[test]
    fn receipt_is_atomic_and_thumbnail_failure_does_not_erase_original_success() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("photo");
        fs::write(&source, b"12345678").unwrap();
        let client = Client::open(root.path().join("client.sqlite"), config()).unwrap();
        let b = batch(&client);
        let input = resource(&source, Some(&b));
        let id = client.enqueue(input.clone()).unwrap();
        let job = client
            .next_prepared(root.path().join(MOBILE_STAGING_DIRECTORY))
            .unwrap()
            .unwrap();
        client.transfer(request(json!({"op":"bind","server":"https://backup.example","account_id":Uuid::new_v4(),"device_id":Uuid::new_v4()}))).unwrap();
        let mut receipt = json!({"op":"receipt","job_id":id,"asset_id":Uuid::new_v4(),"resource_id":Uuid::new_v4(),"content_blake3":"wrong"});
        assert!(client.transfer(request(receipt.clone())).is_err());
        assert_eq!(client.stats().unwrap().complete, 0);
        receipt["content_blake3"] = json!(job.request.content_blake3);
        client.transfer(request(receipt)).unwrap();
        let mut thumbnail = input;
        thumbnail.source_resource_id = "thumbnail".into();
        thumbnail.role = "thumbnail".into();
        let thumb = client.enqueue(thumbnail).unwrap();
        client
            .mark_failed(&thumb, "thumbnail failed", true)
            .unwrap();
        let items = client
            .transfer(request(json!({"op":"items","batch_id":b})))
            .unwrap();
        assert_eq!(items[0]["resources"], 2);
        assert_eq!(items[0]["complete"], 1);
        assert_eq!(items[0]["originals_complete"], 1);
        assert_eq!(client.stats().unwrap().complete, 1);
    }
    #[test]
    fn transfer_contract_rejects_unknown_fields_and_old_identity() {
        assert!(
            serde_json::from_value::<TransferCommand>(json!({"op":"batches","unknown":true}))
                .is_err()
        );
        let root = tempfile::tempdir().unwrap();
        let client = Client::open(root.path().join("client.sqlite"), config()).unwrap();
        let mut old = request(json!({"op":"batches"}));
        old.state_epoch = "media-backup-mobile-v0.3-r1".into();
        assert!(client.transfer(old).is_err());
    }
    #[test]
    fn declared_multiresource_completeness_and_manual_override_are_precise() {
        let root = tempfile::tempdir().unwrap();
        let source = root.path().join("photo");
        fs::write(&source, b"12345678").unwrap();
        let client = Client::open(root.path().join("client.sqlite"), config()).unwrap();
        let b = batch(&client);
        let gallery = |command: Value| {
            client
                .transfer(request(json!({"op":"gallery","command":command})))
                .unwrap()
        };
        gallery(
            json!({"op":"catalog","items":[{"source_id":"asset","name":"Live Photo","media_kind":"photo","album_id":"a","created_ms":1,"modified_ms":1,"size":8,"descriptor":"{}"}]}),
        );
        gallery(
            json!({"op":"declare_resources","source_id":"asset","modified_ms":1,"originals":2}),
        );
        gallery(json!({"op":"exclude","source_id":"asset","excluded":true}));
        let input = resource(&source, Some(&b));
        let id = client.enqueue(input.clone()).unwrap();
        assert_eq!(
            client
                .transfer(request(json!({"op":"active","job_id":id})))
                .unwrap(),
            true
        );
        let account = Uuid::new_v4();
        let device = Uuid::new_v4();
        client.transfer(request(json!({"op":"bind","server":"https://backup.example","account_id":account,"device_id":device}))).unwrap();
        assert!(client.transfer(request(json!({"op":"bind","server":"https://backup.example","account_id":Uuid::new_v4(),"device_id":device}))).is_err());
        let job = client
            .next_prepared(root.path().join(MOBILE_STAGING_DIRECTORY))
            .unwrap()
            .unwrap();
        client.transfer(request(json!({"op":"receipt","job_id":id,"asset_id":Uuid::new_v4(),"resource_id":Uuid::new_v4(),"content_blake3":job.request.content_blake3}))).unwrap();
        let page = || {
            gallery(
                json!({"op":"local_page","album":null,"media_kind":null,"unbacked":false,"offset":0,"limit":100}),
            )
        };
        assert_eq!(page()[0]["backup_state"], "queued");
        let mut motion = input;
        motion.source_resource_id = "motion".into();
        motion.role = "resource-9".into();
        let motion_id = client.enqueue(motion).unwrap();
        client
            .mark_failed(&motion_id, "resource missing", false)
            .unwrap();
        assert_eq!(page()[0]["backup_state"], "failed");
        client
            .transfer(request(json!({"op":"retry_batch","batch_id":b})))
            .unwrap();
        let motion = client
            .next_prepared(root.path().join(MOBILE_STAGING_DIRECTORY))
            .unwrap()
            .unwrap();
        client.transfer(request(json!({"op":"receipt","job_id":motion_id,"asset_id":Uuid::new_v4(),"resource_id":Uuid::new_v4(),"content_blake3":motion.request.content_blake3}))).unwrap();
        client.transfer(request(json!({"op":"set_item","batch_id":b,"item_id":"selected","state":"queued","error":null}))).unwrap();
        assert_eq!(page()[0]["backup_state"], "complete");
        client.transfer(request(json!({"op":"set_item","batch_id":b,"item_id":"selected","state":"blocked","error":"thumbnail export failed"}))).unwrap();
        assert_eq!(page()[0]["backup_state"], "original_complete");
        client.transfer(request(json!({"op":"set_item","batch_id":b,"item_id":"selected","state":"queued","error":null}))).unwrap();

        gallery(json!({"op":"begin_snapshot","sequence":0}));
        gallery(json!({"op":"snapshot_page","cursor":null,"items":[],"next_cursor":null}));
        assert_eq!(page()[0]["backup_state"], "unknown");
        let unknown = gallery(
            json!({"op":"local_page","album":null,"media_kind":null,"unbacked":true,"offset":0,"limit":100}),
        );
        assert_eq!(unknown.as_array().unwrap().len(), 1);
    }
}
