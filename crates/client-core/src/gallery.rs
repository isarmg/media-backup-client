use super::*;
use media_backup_protocol::{AssetSummary, SyncEvent};
use serde_json::{json, Value};

#[derive(Debug, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case", deny_unknown_fields)]
pub enum GalleryCommand {
    BeginCatalog {},
    DeclareResources {
        source_id: String,
        modified_ms: i64,
        originals: u32,
    },
    Catalog {
        items: Vec<LocalAsset>,
    },
    LocalPage {
        album: Option<String>,
        media_kind: Option<String>,
        unbacked: bool,
        offset: u32,
        limit: u32,
    },
    Exclude {
        source_id: String,
        excluded: bool,
    },
    IsExcluded {
        source_id: String,
    },
    State {},
    BeginSnapshot {
        sequence: i64,
    },
    SnapshotPage {
        cursor: Option<String>,
        items: Vec<AssetSummary>,
        next_cursor: Option<String>,
    },
    ApplyEvents {
        expected_sequence: i64,
        next_sequence: i64,
        events: Vec<AppliedEvent>,
    },
    SavePage {
        query_key: String,
        cursor: Option<String>,
        next_cursor: Option<String>,
        items: Vec<AssetSummary>,
    },
    ReadPage {
        query_key: String,
        cursor: Option<String>,
    },
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LocalAsset {
    pub source_id: String,
    pub name: String,
    pub media_kind: String,
    pub album_id: String,
    pub created_ms: i64,
    pub modified_ms: i64,
    pub size: u64,
    pub descriptor: String,
}
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AppliedEvent {
    pub event: SyncEvent,
    pub asset: Option<AssetSummary>,
}
fn save_assets(tx: &rusqlite::Transaction<'_>, items: &[AssetSummary]) -> Result<(), ClientError> {
    for asset in items {
        tx.execute("INSERT INTO gallery_assets(asset_id,summary) VALUES (?1,?2) ON CONFLICT(asset_id) DO UPDATE SET summary=excluded.summary",params![asset.asset_id.to_string(),serde_json::to_string(asset)?])?;
    }
    Ok(())
}
impl Client {
    pub(super) fn gallery(&self, command: GalleryCommand) -> Result<Value, ClientError> {
        let mut connection = self.connection.lock().unwrap_or_else(|p| p.into_inner());
        let tx = connection.transaction()?;
        let value=match command {
            GalleryCommand::DeclareResources {source_id,modified_ms,originals}=>{
                if originals==0{return Err(ClientError::InvalidContract("empty resource set".into()));}
                tx.execute("INSERT INTO source_resource_sets(source_id,modified_ms,originals) VALUES (?1,?2,?3) ON CONFLICT(source_id,modified_ms) DO UPDATE SET originals=excluded.originals",params![source_id,modified_ms,originals])?;Value::Null
            }
            GalleryCommand::BeginCatalog {}=>{tx.execute("UPDATE local_catalog SET available=0",[])?;Value::Null}
            GalleryCommand::Catalog {items}=>{
                if items.len()>1000{return Err(ClientError::InvalidContract("catalog page exceeds 1000".into()));}
                for a in items {tx.execute("INSERT INTO local_catalog(source_id,name,media_kind,album_id,created_ms,modified_ms,size,descriptor,available) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,1)
                    ON CONFLICT(source_id) DO UPDATE SET name=excluded.name,media_kind=excluded.media_kind,album_id=excluded.album_id,created_ms=excluded.created_ms,modified_ms=excluded.modified_ms,size=excluded.size,descriptor=excluded.descriptor,available=1",params![a.source_id,a.name,a.media_kind,a.album_id,a.created_ms,a.modified_ms,a.size,a.descriptor])?;}Value::Null
            }
            GalleryCommand::LocalPage {album,media_kind,unbacked,offset,limit}=>{
                let mut q=tx.prepare("SELECT c.source_id,c.name,c.media_kind,c.album_id,c.created_ms,c.modified_ms,c.size,c.descriptor,
                    EXISTS(SELECT 1 FROM automatic_exclusions e WHERE e.source_id=c.source_id),
                    (SELECT COUNT(*) FROM jobs j JOIN backup_receipts r ON r.job_id=j.id WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND j.role!='thumbnail' AND j.state='complete'),
                    EXISTS(SELECT 1 FROM jobs j WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND j.state='uploading' AND (j.automatic=1 OR EXISTS(SELECT 1 FROM batch_jobs bj JOIN backup_batches b ON b.id=bj.batch_id WHERE bj.job_id=j.id AND b.cancelled=0))),
                    EXISTS(SELECT 1 FROM jobs j WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND j.state IN ('failed','retry_wait') AND (j.automatic=1 OR EXISTS(SELECT 1 FROM batch_jobs bj JOIN backup_batches b ON b.id=bj.batch_id WHERE bj.job_id=j.id AND b.cancelled=0))) OR EXISTS(SELECT 1 FROM batch_jobs bj JOIN backup_batches b ON b.id=bj.batch_id JOIN backup_batch_items bi ON bi.batch_id=bj.batch_id AND bi.id=bj.item_id JOIN jobs j ON j.id=bj.job_id WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND b.cancelled=0 AND bi.state='blocked'),
                    EXISTS(SELECT 1 FROM jobs j WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND j.state IN ('discovered','preparing','ready') AND (j.automatic=1 OR EXISTS(SELECT 1 FROM batch_jobs bj JOIN backup_batches b ON b.id=bj.batch_id WHERE bj.job_id=j.id AND b.cancelled=0))) OR EXISTS(SELECT 1 FROM batch_jobs bj JOIN backup_batches b ON b.id=bj.batch_id JOIN backup_batch_items bi ON bi.batch_id=bj.batch_id AND bi.id=bj.item_id JOIN jobs j ON j.id=bj.job_id WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND b.cancelled=0 AND bi.state='pending'),
                    EXISTS(SELECT 1 FROM jobs j JOIN backup_receipts r ON r.job_id=j.id WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms
                        AND EXISTS(SELECT 1 FROM gallery_state WHERE snapshot_complete=1) AND NOT EXISTS(SELECT 1 FROM gallery_assets g,json_each(g.summary,'$.resources') gr WHERE g.asset_id=r.asset_id AND json_extract(gr.value,'$.resource_id')=r.resource_id))
                     ,COALESCE((SELECT originals FROM source_resource_sets s WHERE s.source_id=c.source_id AND s.modified_ms=c.modified_ms),0)
                    FROM local_catalog c WHERE c.available=1 AND (?1 IS NULL OR c.album_id=?1) AND (?2 IS NULL OR c.media_kind=?2)
                    AND (NOT ?3 OR EXISTS(SELECT 1 FROM batch_jobs bj JOIN backup_batches b ON b.id=bj.batch_id JOIN backup_batch_items bi ON bi.batch_id=bj.batch_id AND bi.id=bj.item_id JOIN jobs j ON j.id=bj.job_id WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND b.cancelled=0 AND bi.state='blocked') OR EXISTS(SELECT 1 FROM batch_jobs bj JOIN backup_batches b ON b.id=bj.batch_id JOIN backup_batch_items bi ON bi.batch_id=bj.batch_id AND bi.id=bj.item_id JOIN jobs j ON j.id=bj.job_id WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND b.cancelled=0 AND bi.state='pending') OR NOT EXISTS(SELECT 1 FROM source_resource_sets s WHERE s.source_id=c.source_id AND s.modified_ms=c.modified_ms AND s.originals=(SELECT COUNT(*) FROM jobs j JOIN backup_receipts r ON r.job_id=j.id WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND j.role!='thumbnail' AND j.state='complete') AND NOT EXISTS(SELECT 1 FROM jobs j WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND j.state!='complete')) OR EXISTS(SELECT 1 FROM jobs j JOIN backup_receipts r ON r.job_id=j.id WHERE j.source_asset_id=c.source_id AND j.modified_ms=c.modified_ms AND EXISTS(SELECT 1 FROM gallery_state WHERE snapshot_complete=1) AND NOT EXISTS(SELECT 1 FROM gallery_assets g,json_each(g.summary,'$.resources') gr WHERE g.asset_id=r.asset_id AND json_extract(gr.value,'$.resource_id')=r.resource_id)))
                    ORDER BY c.created_ms DESC,c.source_id LIMIT ?4 OFFSET ?5")?;
                let rows=q.query_map(params![album,media_kind,unbacked,limit.clamp(1,1000),offset],|r|{
                    let originals:u64=r.get(9)?;let uploading:bool=r.get(10)?;let failed:bool=r.get(11)?;let queued:bool=r.get(12)?;let unknown:bool=r.get(13)?;
                    let expected:u64=r.get(14)?;let all_originals=expected>0&&originals>=expected;
                    let state=if unknown{"unknown"}else if uploading{"uploading"}else if all_originals&&failed{"original_complete"}else if failed{"failed"}else if queued{"queued"}else if all_originals{"complete"}else{"unknown"};
                    Ok(json!({"source_id":r.get::<_,String>(0)?,"name":r.get::<_,String>(1)?,"media_kind":r.get::<_,String>(2)?,"album_id":r.get::<_,String>(3)?,"created_ms":r.get::<_,i64>(4)?,"modified_ms":r.get::<_,i64>(5)?,"size":r.get::<_,u64>(6)?,"descriptor":r.get::<_,String>(7)?,"excluded":r.get::<_,bool>(8)?,"backup_state":state}))
                })?.collect::<Result<Vec<_>,_>>()?;json!(rows)
            }
            GalleryCommand::Exclude {source_id,excluded}=>{
                if excluded {tx.execute("INSERT OR IGNORE INTO automatic_exclusions(source_id) VALUES (?1)",params![source_id])?;
                    tx.execute("UPDATE jobs SET automatic=0 WHERE source_asset_id=?1 AND state!='complete'",params![source_id])?;
                }else{tx.execute("DELETE FROM automatic_exclusions WHERE source_id=?1",params![source_id])?;}Value::Null
            }
            GalleryCommand::IsExcluded {source_id}=>json!(tx.query_row("SELECT EXISTS(SELECT 1 FROM automatic_exclusions WHERE source_id=?1)",params![source_id],|r|r.get::<_,bool>(0))?),
            GalleryCommand::State {}=>tx.query_row("SELECT sequence,snapshot_cursor,snapshot_complete FROM gallery_state",[],|r|Ok(json!({"sequence":r.get::<_,i64>(0)?,"snapshot_cursor":r.get::<_,Option<String>>(1)?,"snapshot_complete":r.get::<_,bool>(2)?}))).optional()?.unwrap_or(Value::Null),
            GalleryCommand::BeginSnapshot {sequence}=>{
                if sequence<0{return Err(ClientError::InvalidContract("negative sync sequence".into()));}
                tx.execute("DELETE FROM gallery_assets",[])?;tx.execute("DELETE FROM gallery_pages",[])?;
                tx.execute("INSERT INTO gallery_state(singleton,sequence,snapshot_cursor,snapshot_complete) VALUES (1,?1,NULL,0) ON CONFLICT(singleton) DO UPDATE SET sequence=excluded.sequence,snapshot_cursor=NULL,snapshot_complete=0",params![sequence])?;Value::Null
            }
            GalleryCommand::SnapshotPage {cursor,items,next_cursor}=>{
                let (saved,complete):(Option<String>,bool)=tx.query_row("SELECT snapshot_cursor,snapshot_complete FROM gallery_state",[],|r|Ok((r.get(0)?,r.get(1)?)))?;
                if complete||saved!=cursor||next_cursor.is_some()&&next_cursor==cursor{return Err(ClientError::InvalidContract("snapshot cursor conflict".into()));}
                save_assets(&tx,&items)?;
                tx.execute("UPDATE gallery_state SET snapshot_cursor=?1,snapshot_complete=?2",params![next_cursor,next_cursor.is_none()])?;Value::Null
            }
            GalleryCommand::ApplyEvents {expected_sequence,next_sequence,events}=>{
                let (saved,complete):(i64,bool)=tx.query_row("SELECT sequence,snapshot_complete FROM gallery_state",[],|r|Ok((r.get(0)?,r.get(1)?)))?;
                if !complete||saved!=expected_sequence||next_sequence<saved{return Err(ClientError::InvalidContract("sync sequence conflict".into()));}
                let mut last=saved;
                for change in events {
                    let event=change.event;
                    if event.sequence<=last||event.sequence>next_sequence{return Err(ClientError::InvalidContract("unordered sync events".into()));}last=event.sequence;
                    if event.entity_kind=="asset" {
                        if let Some(asset)=change.asset {
                            if asset.asset_id!=event.entity_id{return Err(ClientError::InvalidContract("event asset mismatch".into()));}
                            save_assets(&tx,&[asset])?;
                        }else{tx.execute("DELETE FROM gallery_assets WHERE asset_id=?1",params![event.entity_id.to_string()])?;}
                    }
                }
                if last!=next_sequence{return Err(ClientError::InvalidContract("unapplied sequence cannot advance".into()));}
                tx.execute("UPDATE gallery_state SET sequence=?1",params![next_sequence])?;
                // Query membership may have changed; visible pages are refreshed from the server.
                if next_sequence>expected_sequence {tx.execute("DELETE FROM gallery_pages",[])?;}Value::Null
            }
            GalleryCommand::SavePage {query_key,cursor,next_cursor,items}=>{
                save_assets(&tx,&items)?;
                let ids=items.iter().map(|a|a.asset_id.to_string()).collect::<Vec<_>>();
                tx.execute("INSERT INTO gallery_pages(query_key,cursor,next_cursor,asset_ids) VALUES (?1,?2,?3,?4) ON CONFLICT(query_key,cursor) DO UPDATE SET next_cursor=excluded.next_cursor,asset_ids=excluded.asset_ids",params![query_key,cursor.unwrap_or_default(),next_cursor,serde_json::to_string(&ids)?])?;Value::Null
            }
            GalleryCommand::ReadPage {query_key,cursor}=>{
                let page:Option<(Option<String>,String)>=tx.query_row("SELECT next_cursor,asset_ids FROM gallery_pages WHERE query_key=?1 AND cursor=?2",params![query_key,cursor.unwrap_or_default()],|r|Ok((r.get(0)?,r.get(1)?))).optional()?;
                if let Some((next,ids))=page{let mut items=Vec::new();for id in serde_json::from_str::<Vec<String>>(&ids)? {
                    if let Some(summary)=tx.query_row("SELECT summary FROM gallery_assets WHERE asset_id=?1",params![id],|r|r.get::<_,String>(0)).optional()?{items.push(serde_json::from_str::<Value>(&summary)?);}
                }json!({"items":items,"next_cursor":next})}else{Value::Null}
            }
        };
        tx.commit()?;
        Ok(value)
    }
}

#[cfg(test)]
mod tests {
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
        let conn = c.connection.lock().unwrap();
        assert_eq!(
            conn.query_row("SELECT COUNT(*) FROM gallery_assets", [], |r| r
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
        call(&c,json!({"op":"save_page","query_key":"photos","cursor":null,"next_cursor":null,"items":[]})).unwrap();
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
        call(&c,json!({"op":"catalog","items":[{"source_id":"local","name":"photo","media_kind":"photo","album_id":"album","created_ms":2,"modified_ms":1,"size":8,"descriptor":"{}"}]})).unwrap();
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
        assert!(call(&c,json!({"op":"local_page","album":null,"media_kind":null,"unbacked":false,"offset":0,"limit":100})).unwrap().as_array().unwrap().is_empty());
    }
}
