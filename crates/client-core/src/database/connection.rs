//! Synchronous mobile business operations over SQLx's direct SQLite worker.
//! SQL strings remain SQLx-checked shapes; values are always bound arguments.
use sqlx::{
    sqlite::{SqliteArguments, SqliteConnectOptions, SqliteRow},
    Arguments, Connection as _, Row as _, SqlSafeStr, SqlStr, Sqlite, SqliteConnection,
};
#[cfg(test)]
use std::path::Path;

pub(crate) type Result<T> = std::result::Result<T, sqlx::Error>;
pub(crate) struct Connection {
    inner: Option<SqliteConnection>,
}
pub(crate) struct Transaction<'a> {
    inner: Option<sqlx::Transaction<'a, Sqlite>>,
}
pub(crate) struct Statement<'a> {
    connection: &'a mut SqliteConnection,
    sql: SqlStr,
}
pub(crate) struct Row(SqliteRow);
pub(crate) struct BindArguments {
    arguments: SqliteArguments,
    error: Option<sqlx::Error>,
}
macro_rules! params {
    () => { $crate::database::connection::BindArguments::new() };
    ($($value:expr),* $(,)?) => {{
        let mut arguments = $crate::database::connection::BindArguments::new();
        $(arguments.bind(&$value);)*
        arguments
    }};
}
pub(crate) use params;
impl BindArguments {
    pub(crate) fn new() -> Self {
        Self {
            arguments: SqliteArguments::default(),
            error: None,
        }
    }
    pub(crate) fn bind<T: Binding + ?Sized>(&mut self, value: &T) {
        if self.error.is_none() {
            self.error = value.bind(&mut self.arguments).err();
        }
    }
    fn finish(self) -> Result<SqliteArguments> {
        match self.error {
            Some(error) => Err(error),
            None => Ok(self.arguments),
        }
    }
}
pub(crate) trait Binding {
    fn bind(&self, arguments: &mut SqliteArguments) -> Result<()>;
}
macro_rules! binding {
    ($($kind:ty),*) => { $(impl Binding for $kind {
        fn bind(&self, arguments: &mut SqliteArguments) -> Result<()> {
            arguments.add(self.clone()).map_err(sqlx::Error::Encode)
        }
    })* };
}
binding!(String, Vec<u8>);
macro_rules! scalar_binding {
 ($($kind:ty),*) => { $(impl Binding for $kind { fn bind(&self, arguments: &mut SqliteArguments) -> Result<()> { arguments.add(*self).map_err(sqlx::Error::Encode) } })* };
}
scalar_binding!(i64, i32, f64, bool);
impl Binding for str {
    fn bind(&self, arguments: &mut SqliteArguments) -> Result<()> {
        arguments.add(self.to_owned()).map_err(sqlx::Error::Encode)
    }
}
impl<T: Binding + ?Sized> Binding for &T {
    fn bind(&self, arguments: &mut SqliteArguments) -> Result<()> {
        (*self).bind(arguments)
    }
}
impl<T: Binding> Binding for Option<T> {
    fn bind(&self, arguments: &mut SqliteArguments) -> Result<()> {
        match self {
            Some(value) => value.bind(arguments),
            None => arguments.add(None::<String>).map_err(sqlx::Error::Encode),
        }
    }
}
macro_rules! checked_integer_binding {
    ($($kind:ty),*) => { $(impl Binding for $kind { fn bind(&self, arguments: &mut SqliteArguments) -> Result<()> {
        let value = i64::try_from(*self).map_err(|_| sqlx::Error::Encode("integer exceeds SQLite signed range".into()))?;
        arguments.add(value).map_err(sqlx::Error::Encode)
    } })* };
}
checked_integer_binding!(u64, usize, u32);
pub(crate) trait Parameters {
    fn arguments(self) -> Result<SqliteArguments>;
}
impl Parameters for BindArguments {
    fn arguments(self) -> Result<SqliteArguments> {
        self.finish()
    }
}
impl<T: Binding, const N: usize> Parameters for [T; N] {
    fn arguments(self) -> Result<SqliteArguments> {
        let mut arguments = BindArguments::new();
        for value in self {
            arguments.bind(&value);
        }
        arguments.finish()
    }
}
pub(crate) trait DecodeValue: Sized {
    fn decode(row: &SqliteRow, index: usize) -> Result<Self>;
}
macro_rules! decode {
    ($($kind:ty),*) => { $(impl DecodeValue for $kind { fn decode(row: &SqliteRow, index: usize) -> Result<Self> { row.try_get(index) } })* };
}
decode!(String, i64, i32, bool, f64, Vec<u8>);
impl DecodeValue for u32 {
    fn decode(row: &SqliteRow, index: usize) -> Result<Self> {
        let value: i64 = row.try_get(index)?;
        u32::try_from(value)
            .map_err(|_| sqlx::Error::Decode("SQLite value exceeds unsigned field range".into()))
    }
}
impl DecodeValue for u64 {
    fn decode(row: &SqliteRow, index: usize) -> Result<Self> {
        let value: i64 = row.try_get(index)?;
        u64::try_from(value)
            .map_err(|_| sqlx::Error::Decode("negative SQLite value for unsigned field".into()))
    }
}
impl<T: DecodeValue> DecodeValue for Option<T> {
    fn decode(row: &SqliteRow, index: usize) -> Result<Self> {
        use sqlx::ValueRef;
        if row.try_get_raw(index)?.is_null() {
            Ok(None)
        } else {
            T::decode(row, index).map(Some)
        }
    }
}
impl Row {
    #[cfg(test)]
    pub(crate) fn column_count(&self) -> usize {
        self.0.len()
    }
    pub(crate) fn get<I: TryInto<usize>, T: DecodeValue>(&self, index: I) -> Result<T> {
        T::decode(
            &self.0,
            index
                .try_into()
                .map_err(|_| sqlx::Error::Decode("invalid SQLite column index".into()))?,
        )
    }
}
impl Connection {
    pub(crate) fn connect(options: &SqliteConnectOptions) -> Result<Self> {
        xcsc::runtime::block_on_worker_future(SqliteConnection::connect_with(options))
            .map(|inner| Self { inner: Some(inner) })
    }
    #[cfg(test)]
    pub(crate) fn open(path: &Path) -> Result<Self> {
        Self::connect(
            &SqliteConnectOptions::new()
                .filename(path)
                .create_if_missing(true),
        )
    }
    fn inner(&mut self) -> &mut SqliteConnection {
        self.inner
            .as_mut()
            .expect("connection remains owned until drop")
    }
    pub(crate) fn execute_batch(&mut self, sql: impl SqlSafeStr) -> Result<()> {
        xcsc::runtime::block_on_worker_future(sqlx::raw_sql(sql).execute(self.inner())).map(|_| ())
    }
    pub(crate) fn execute(
        &mut self,
        sql: impl SqlSafeStr,
        parameters: impl Parameters,
    ) -> Result<u64> {
        execute(self.inner(), sql, parameters)
    }
    pub(crate) fn query_row<T>(
        &mut self,
        sql: impl SqlSafeStr,
        parameters: impl Parameters,
        map: impl FnOnce(&Row) -> Result<T>,
    ) -> Result<T> {
        query_row(self.inner(), sql, parameters, map)
    }
    pub(crate) fn prepare(&mut self, sql: impl SqlSafeStr) -> Result<Statement<'_>> {
        Ok(Statement {
            sql: sql.into_sql_str(),
            connection: self.inner(),
        })
    }
    pub(crate) fn transaction(&mut self) -> Result<Transaction<'_>> {
        xcsc::runtime::block_on_worker_future(self.inner().begin())
            .map(|inner| Transaction { inner: Some(inner) })
    }
}
impl Drop for Connection {
    fn drop(&mut self) {
        // Await worker shutdown before snapshot directories or native pins can drop.
        if let Some(inner) = self.inner.take() {
            let _ = xcsc::runtime::block_on_worker_future(inner.close());
        }
    }
}
impl Transaction<'_> {
    fn connection(&mut self) -> &mut SqliteConnection {
        self.inner
            .as_mut()
            .expect("transaction remains owned until commit")
            .as_mut()
    }
    pub(crate) fn execute(
        &mut self,
        sql: impl SqlSafeStr,
        parameters: impl Parameters,
    ) -> Result<u64> {
        execute(self.connection(), sql, parameters)
    }
    pub(crate) fn query_row<T>(
        &mut self,
        sql: impl SqlSafeStr,
        parameters: impl Parameters,
        map: impl FnOnce(&Row) -> Result<T>,
    ) -> Result<T> {
        query_row(self.connection(), sql, parameters, map)
    }
    pub(crate) fn prepare(&mut self, sql: impl SqlSafeStr) -> Result<Statement<'_>> {
        Ok(Statement {
            sql: sql.into_sql_str(),
            connection: self.connection(),
        })
    }
    pub(crate) fn commit(mut self) -> Result<()> {
        xcsc::runtime::block_on_worker_future(
            self.inner.take().expect("owned transaction").commit(),
        )
    }
}
impl Drop for Transaction<'_> {
    fn drop(&mut self) {
        if let Some(inner) = self.inner.take() {
            let _ = xcsc::runtime::block_on_worker_future(inner.rollback());
        }
    }
}
fn execute(
    connection: &mut SqliteConnection,
    sql: impl SqlSafeStr,
    parameters: impl Parameters,
) -> Result<u64> {
    xcsc::runtime::block_on_worker_future(
        sqlx::query_with(sql, parameters.arguments()?).execute(connection),
    )
    .map(|done| done.rows_affected())
}
fn query_row<T>(
    connection: &mut SqliteConnection,
    sql: impl SqlSafeStr,
    parameters: impl Parameters,
    map: impl FnOnce(&Row) -> Result<T>,
) -> Result<T> {
    let row = xcsc::runtime::block_on_worker_future(
        sqlx::query_with(sql, parameters.arguments()?).fetch_one(connection),
    )?;
    map(&Row(row))
}
type RowStream<'a> =
    std::pin::Pin<Box<dyn futures_util::Stream<Item = Result<SqliteRow>> + Send + 'a>>;
impl Statement<'_> {
    pub(crate) fn query_map<'a, T, F: FnMut(&Row) -> Result<T>>(
        &'a mut self,
        parameters: impl Parameters,
        map: F,
    ) -> Result<MappedRows<'a, T, F>> {
        let stream = sqlx::query_with(self.sql.clone(), parameters.arguments()?)
            .fetch(&mut *self.connection);
        Ok(MappedRows { stream, map })
    }
    pub(crate) fn query(&mut self, parameters: impl Parameters) -> Result<Rows<'_>> {
        let stream = sqlx::query_with(self.sql.clone(), parameters.arguments()?)
            .fetch(&mut *self.connection);
        Ok(Rows {
            stream,
            current: None,
        })
    }
}
pub(crate) struct MappedRows<'a, T, F: FnMut(&Row) -> Result<T>> {
    stream: RowStream<'a>,
    map: F,
}
impl<T, F: FnMut(&Row) -> Result<T>> Iterator for MappedRows<'_, T, F> {
    type Item = Result<T>;
    fn next(&mut self) -> Option<Self::Item> {
        use futures_util::StreamExt;
        xcsc::runtime::block_on_worker_future(self.stream.next())
            .map(|row| row.and_then(|row| (self.map)(&Row(row))))
    }
}
pub(crate) trait OptionalExtension<T> {
    fn optional(self) -> Result<Option<T>>;
}
impl<T> OptionalExtension<T> for Result<T> {
    fn optional(self) -> Result<Option<T>> {
        match self {
            Ok(value) => Ok(Some(value)),
            Err(sqlx::Error::RowNotFound) => Ok(None),
            Err(error) => Err(error),
        }
    }
}

pub(crate) struct Rows<'a> {
    stream: RowStream<'a>,
    current: Option<Row>,
}
impl Rows<'_> {
    pub(crate) fn next(&mut self) -> Result<Option<&Row>> {
        use futures_util::StreamExt;
        self.current = xcsc::runtime::block_on_worker_future(self.stream.next())
            .transpose()?
            .map(Row);
        Ok(self.current.as_ref())
    }
}

#[cfg(test)]
#[derive(Debug, PartialEq)]
pub(crate) enum SqliteValue {
    Null,
    Integer(i64),
    Real(f64),
    Text(Vec<u8>),
    Blob(Vec<u8>),
}
#[cfg(test)]
impl DecodeValue for SqliteValue {
    fn decode(row: &SqliteRow, index: usize) -> Result<Self> {
        use sqlx::{TypeInfo, ValueRef};
        let raw = row.try_get_raw(index)?;
        if raw.is_null() {
            return Ok(Self::Null);
        }
        match raw.type_info().name() {
            "INTEGER" => row.try_get(index).map(Self::Integer),
            "REAL" => row.try_get(index).map(Self::Real),
            "TEXT" => row.try_get_unchecked(index).map(Self::Text),
            "BLOB" => row.try_get(index).map(Self::Blob),
            _ => Err(sqlx::Error::Decode(
                "unexpected SQLite storage class".into(),
            )),
        }
    }
}

#[cfg(test)]
mod tests;
