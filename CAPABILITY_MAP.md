# Capability Map: FennecCast iOS

FennecCast 是以 AntennaPod 3.12.0 为行为参考、面向个人长期使用的原生 iOS 播客客户端。首轮交付以白皮书 v1.1 的 P0/MVP 为范围；P1、P2 在 P0 验收后增量实施。

| Module id | Responsibility | Depends on |
|---|---|---|
| `app-foundation` | Xcode 工程、GPL、应用环境、本地化与测试骨架 | — |
| `core-contracts` | Feed/Episode 稳定身份、HLC、同步模型与合并规则 | `app-foundation` |
| `local-data` | GRDB、Migration、Repository、Outbox、Cursor 与 Alias | `core-contracts` |
| `feed-library` | 添加/刷新订阅、RSS/Atom、Episode、Inbox、收藏与筛选 | `local-data` |
| `queue` | 队列增删移动、Fractional Index、墓碑与自动推进 | `local-data` |
| `playback` | AVPlayer、后台音频、锁屏控制、倍速、进度、章节与睡眠定时 | `feed-library`, `queue` |
| `downloads` | Background URLSession、恢复、重试与本地文件管理 | `feed-library` |
| `state-sync` | Keychain、`/v1/sync`、三类状态合并与离线重试 | `local-data`, `queue`, `playback` |
| `app-experience` | SwiftUI 首页、订阅、列表、队列、播放器、下载与设置 | `feed-library`, `queue`, `playback`, `downloads`, `state-sync` |
| `import-export` | OPML 导入与设备本地备份 | `local-data`, `feed-library` |

Build order:

`app-foundation` → `core-contracts` → `local-data` → (`feed-library`, `queue`) → (`playback`, `downloads`) → `state-sync` → `app-experience` → `import-export`

## Initiative boundaries

- iOS 客户端代码位于本目录，作为独立 GPL-3.0 工程管理。
- 首轮仅实现 iOS 客户端。NAS 服务端和 Android Adapter 不在本工程代码范围内。
- StateSync Lite v1 只同步订阅、播放状态和队列。
- Inbox、收藏、标签、设置、下载任务、媒体文件和缓存保持设备本地。
- 最低支持 iOS 17，使用 SwiftUI、Observation、GRDB 和 AVFoundation。
- 界面提供英文与简体中文。

