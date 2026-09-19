# 移动图库接口消费范围

Android 与 iOS 当前都消费云端时间线、详情、筛选、相册、收藏/归档、回收站、单项标签、永久删除、
重复项分组、资源预览和视频分段读取。危险删除只在回收站资产详情出现，并要求二次确认。

移动端没有接入以下账户自动化接口：

- `PUT /v2/tags/{tag_id}/assets`：这是全量成员替换，保留给显式批处理工具；移动端使用单资产
  `POST/DELETE`，避免一次误选覆盖整个标签成员集合。
- `/v2/api-keys`：API Key 用于额外客户端和自动化，原值只在创建时返回；不由日常图库代管。
- `/v2/audit-events`：账户审计由持账户凭据的诊断工具分页读取，不与 Server 管理员审计混合。

这些边界与 Server 的 [接口与消费者边界](https://github.com/isarmg/media-backup-server/blob/main/docs/interface-consumers.md)
保持一致。移动端不得使用管理员 Cookie，也不得为了显示账户接口而持有 Server 管理员密码。
