# Media Backup 文档总览

本文档集描述仓库当前 `0.4.10` 代码。代码、Schema、发行 manifest 与自动化测试是最终事实源；文档与
实现不一致时，应先确认当前代码，再在同一变更中修正文档和测试。

| 分类 | 入口 | 适合读者 | 解决的问题 |
|---|---|---|---|
| 初学者学习指南 | [beginner-guide/README.md](beginner-guide/README.md) | 第一次接触 Rust 或移动备份的开发者 | 如何建立心智模型、运行项目并安全修改代码 |
| 工作流程与流程树 | [project-workflow.md](project-workflow.md) | 开发、评审和排障人员 | 请求、上传、同步、恢复、发行如何流转 |
| 完整功能与取舍 | [feature-inventory-and-tradeoffs.md](feature-inventory-and-tradeoffs.md) | 产品、架构和维护人员 | 已实现什么、明确不做什么、为什么 |
| 接口消费者边界 | [interface-consumers.md](interface-consumers.md) | 产品、客户端和 API 工具维护人员 | 哪些接口进入移动界面，哪些保留给账户自动化 |
| 必要 README | [../README.md](../README.md) | 所有人 | 项目定位、入口、最短验证路径 |
| Client 运维 | [operations.md](operations.md) | 移动端测试、值班和发布人员 | Android/iOS 构建、权限、队列、配对、故障与发布边界 |

阅读建议：初学者按表格从上到下阅读；处理线上问题时直接从运维文档的“故障定位顺序”开始；修改
协议、Schema 或发行布局前，必须同时阅读工作流程与功能取舍清单。

- [手动备份与分页云端图库实施记录](manual-backup-implementation.md)
- [0.4.2 登录与布局更新](releases/0.4.2.md)
- [0.4.1 iOS 27 发行说明](releases/0.4.1.md)
- [0.4.0 发行说明](releases/0.4.0.md)
