import Foundation
import GRDB

// MARK: - Database Bootstrap（集中式数据库迁移）

/// 数据库集中初始化：所有表结构与索引在这里注册为命名稳定的 GRDB 迁移，
/// 由 `SpaceStore` 打开数据库后立即运行。
///
/// 失败语义：迁移失败即抛错 → 调用方（`SpaceStore`）判定该库不可用并返回 nil，
/// 不再构造任何依赖它的服务，避免「应用看似启动成功、某个页面稍后随机报错」的失败模式。
///
/// 幂等性：历史版本的建表逻辑本是幂等的（`ifNotExists` + 缺失列检查），
/// 因此对已存在但缺少 `grdb_migrations` 记录的旧库执行 v1 迁移是安全的。
public enum DatabaseBootstrap {

    /// 全局库迁移：LLM 提供者配置等非隐私数据
    public static func prepareGlobal(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_llm_providers") { db in
            try ProviderConfigService.createSchema(db)
        }
        migrator.registerMigration("v2_llm_providers_alias") { db in
            try ProviderConfigService.addAliasColumn(db)
        }
        migrator.registerMigration("v3_llm_providers_order") { db in
            try ProviderConfigService.addSortOrderColumn(db)
        }
        migrator.registerMigration("v1_model_parameters") { db in
            try ModelParameterService.createSchema(db)
        }
        try migrator.migrate(queue)
    }

    /// 空间库迁移：会话 / 智体 / 技能 / 记忆 / 知识（每空间独立库，各自迁移）
    public static func prepareSpace(_ queue: DatabaseQueue) throws {
        queue.writeWithoutTransaction { MailService.installConversationFunction($0) }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v5_note_capture_reports") { db in
            try NoteStore.createSchema(db)
            try NoteStore.createCaptureReportSchema(db)
        }
        migrator.registerMigration("v4_note_voiceprints") { db in
            try NoteStore.createVoiceprintSchema(db)
        }
        migrator.registerMigration("v3_note_workflows") { db in
            try NoteStore.createSchema(db)
            try NoteStore.createWorkflowSchema(db)
        }
        migrator.registerMigration("v2_note_transcription") { db in
            try NoteStore.createSchema(db)
            try NoteStore.createTranscriptionSchema(db)
        }
        migrator.registerMigration("v1_notes") { db in
            try NoteStore.createSchema(db)
        }
        migrator.registerMigration("v1_agents") { db in
            try AgentService.createSchema(db)
        }
        migrator.registerMigration("v1_skills") { db in
            try SkillService.createSchema(db)
        }
        migrator.registerMigration("v1_memories") { db in
            try MemoryService.createSchema(db)
        }
        // 记忆分类：v1 已对旧库标记为完成，不会重跑，故补一条独立迁移加列
        migrator.registerMigration("v2_memories_category") { db in
            try MemoryService.addCategoryColumn(db)
        }
        migrator.registerMigration("v3_memories_source") { db in
            try MemoryService.createSchema(db)
            try MemoryService.addSourceColumns(db)
        }
        migrator.registerMigration("v1_knowledge") { db in
            try KnowledgeService.createSchema(db)
        }
        migrator.registerMigration("v2_knowledge_embeddings") { db in
            // 兼容迁移记录存在、但旧备份未含知识表的历史数据库。
            try KnowledgeService.createSchema(db)
            try KnowledgeRetrievalService.createSchema(db)
        }
        migrator.registerMigration("v3_knowledge_hierarchy") { db in
            try KnowledgeService.addHierarchyColumns(db)
        }
        migrator.registerMigration("v1_chat") { db in
            try SessionService.createSchema(db)
        }
        // 自动审核开关列：v1_chat 对已迁移的旧库不会重跑，故补一条独立迁移加列
        migrator.registerMigration("v2_chat_auto_review") { db in
            try SessionService.addAutoReviewColumn(db)
        }
        // 会话归档列：同上，独立迁移保证旧库补齐 isArchived
        migrator.registerMigration("v3_chat_archive") { db in
            try SessionService.addIsArchivedColumn(db)
        }
        // 会话权限模式列：旧库默认完全权限，保持升级前行为
        migrator.registerMigration("v4_chat_permission_mode") { db in
            try SessionService.addPermissionModeColumn(db)
        }
        migrator.registerMigration("v5_chat_restore_versions") { db in
            try SessionService.createRestoreSchema(db)
        }
        migrator.registerMigration("v1_mail") { db in
            try MailService.createSchema(db)
        }
        migrator.registerMigration("v7_mail_integrity") { db in
            try MailService.createSchema(db)
            try MailService.addIntegrityGuards(db)
        }
        // 草稿投递凭证列：v1 建表时还没有「已投递」标记，旧库需补列
        migrator.registerMigration("v2_mail_draft_delivery") { db in
            try MailService.addDraftDeliveryColumns(db)
        }
        migrator.registerMigration("v3_mail_attachment_part") { db in
            try MailService.createSchema(db)
            try MailService.addAttachmentPartColumn(db)
        }
        // 文件夹层级列：parentPath / delimiter / isContainer 支撑侧栏树形分组
        migrator.registerMigration("v4_mail_folder_hierarchy") { db in
            try MailService.createSchema(db)
            try MailService.addFolderHierarchyColumns(db)
        }
        // 回复上下文列：Reply-To 与 References，支撑回复地址与线程链
        migrator.registerMigration("v5_mail_reply_context") { db in
            try MailService.createSchema(db)
            try MailService.addReplyContextColumns(db)
        }
        // 草稿来源列：撰写类型、原邮件身份与「原文引用」分离存储
        migrator.registerMigration("v6_mail_draft_source") { db in
            try MailService.createSchema(db)
            try MailService.addDraftSourceColumns(db)
        }
        migrator.registerMigration("v9_mail_raw_messages") { db in
            try MailService.createRawSchema(db)
        }
        migrator.registerMigration("v10_mail_draft_attachments") { db in
            try MailService.addDraftAttachmentColumns(db)
        }
        migrator.registerMigration("v11_mail_local_archives") { db in
            try MailService.createImportSchema(db)
        }
        migrator.registerMigration("v12_mail_import_undo") { db in
            try MailService.createImportUndoSchema(db)
        }
        migrator.registerMigration("v13_mail_search") { db in
            try MailService.createSearchSchema(db)
        }
        migrator.registerMigration("v14_mail_folder_preferences") { db in
            try MailService.createFolderPreferenceSchema(db)
        }
        migrator.registerMigration("v15_mail_conversations") { db in
            try MailService.createConversationSchema(db)
        }
        migrator.registerMigration("v16_mail_import_review") { db in
            try MailService.createImportReviewSchema(db)
        }
        migrator.registerMigration("v17_mail_folder_visibility") { db in
            try MailService.addFolderVisibilitySchema(db)
        }
        migrator.registerMigration("v18_mail_folder_mutations") { db in
            try MailService.createFolderMutationSchema(db)
        }
        migrator.registerMigration("v19_mail_server_drafts") { db in
            try MailService.createServerDraftSchema(db)
        }
        migrator.registerMigration("v1_mail_draft_text_styles") { db in
            if try !db.columns(in: "mail_drafts").contains(where: { $0.name == "bodyStylesData" }) {
                try db.alter(table: "mail_drafts") { $0.add(column: "bodyStylesData", .blob) }
            }
        }
        // 多智体协作任务快照：计划 + 最近报告，供任务板与重启后回看
        migrator.registerMigration("v1_team_tasks") { db in
            try TeamTaskStore.createSchema(db)
        }
        // 团队运行身份与迟到写入保护：旧任务补 runID / runVersion / parentTaskID。
        migrator.registerMigration("v2_team_task_runs") { db in
            try TeamTaskStore.createSchema(db)
            try TeamTaskStore.addRunColumns(db)
        }
        // 团队写快照：旧内容 + 新内容，供任务板审阅与单文件回滚
        migrator.registerMigration("v1_team_writes") { db in
            try TeamWriteStore.createSchema(db)
        }
        // 写快照状态机：prepared / applied / failed / reverted / needsRecovery。
        migrator.registerMigration("v2_team_write_states") { db in
            try TeamWriteStore.createSchema(db)
            try TeamWriteStore.addStateColumns(db)
        }
        // 团队写审批审计：决定、原因、稳定标识；正文不入审计。
        migrator.registerMigration("v3_team_approval_audit") { db in
            try TeamWriteStore.createSchema(db)
        }
        // 定时任务定义：触发规则 + 能力档版本，不含运行结果
        migrator.registerMigration("v1_scheduled_tasks") { db in
            try ScheduledTaskStore.createSchema(db)
        }
        // 定时运行记录：(taskID, scheduledFor) 唯一索引防重复触发
        migrator.registerMigration("v1_scheduled_runs") { db in
            try ScheduledRunStore.createSchema(db)
        }
        // 任务文件恢复点：保存修改前内容与 AI 写入摘要，供同空间恢复。
        migrator.registerMigration("v1_task_file_recoveries") { db in
            try TaskFileRecoveryStore.createSchema(db)
        }
        migrator.registerMigration("v1_mcp_servers") { db in
            try MCPServerConfigService.createSchema(db)
        }
        migrator.registerMigration("v1_mysql_connections") { db in
            try MySQLConnectorService.createSchema(db)
        }
        migrator.registerMigration("v1_coding_tasks") { db in
            try CodingTaskStore.createSchema(db)
        }
        migrator.registerMigration("v1_provider_usage") { db in
            try UsageService.createSchema(db)
            try SessionService.backfillUsage(db)
        }
        migrator.registerMigration("v2_provider_usage_breakdown") { db in
            try UsageService.addBreakdownColumns(db)
        }

        migrator.registerMigration("v1_knowledge_graph") { db in
            try KnowledgeGraphService.createSchema(db)
        }
        migrator.registerMigration("v1_product_preferences") { db in
            try ProductPreferencesService.createSchema(db)
        }
        migrator.registerMigration("v1_workspace_projects") { db in
            try WorkspaceProjectStore.createSchema(db)
        }
        migrator.registerMigration("v1_execution_goals") { db in
            try GoalStore.createSchema(db)
        }
        migrator.registerMigration("v1_product_events") { db in
            try ProductPreferencesService.createMetricsSchema(db)
        }
        migrator.registerMigration("v8_mail_sync_coverage") { db in
            try MailService.createCoverageSchema(db)
        }
        migrator.registerMigration("v1_mail_agent_draft_receipts") { db in
            try MailService.createAgentDraftReceiptSchema(db)
        }
        migrator.registerMigration("v1_product_task_runs") { db in
            try ProductTaskRunStore.createSchema(db)
            try ProductTaskRunStore.backfill(db)
        }
        migrator.registerMigration("v1_product_job_runs") { db in
            try ProductJobRunStore.createSchema(db)
        }
        migrator.registerMigration("v1_artifact_versions") { db in
            try TaskArtifactStore.createSchema(db)
        }
        migrator.registerMigration("v2_artifact_library") { db in
            try TaskArtifactStore.createSchema(db)
        }
        migrator.registerMigration("v3_artifact_comparisons") { db in
            try TaskArtifactStore.createComparisonSchema(db)
        }
        migrator.registerMigration("v1_knowledge_imports") { db in
            try KnowledgeImportService.createSchema(db)
        }
        migrator.registerMigration("v2_scheduled_experience") { db in
            if !(try db.columns(in: "scheduled_tasks")).contains(where: { $0.name == "optionsJSON" }) {
                try db.alter(table: "scheduled_tasks") { $0.add(column: "optionsJSON", .text) }
            }
            if !(try db.columns(in: "scheduled_runs")).contains(where: { $0.name == "experienceJSON" }) {
                try db.alter(table: "scheduled_runs") { $0.add(column: "experienceJSON", .text) }
            }
        }
        migrator.registerMigration("v1_product_task_center_cleared") { db in
            try ProductTaskCenterStore.createSchema(db)
        }
        migrator.registerMigration("v2_agent_model_provider") { db in
            try AgentService.createSchema(db)
        }
        migrator.registerMigration("v1_first_task_guidance") { db in
            try ProductPreferencesService.backfillFirstTaskGuidance(db)
        }
        migrator.registerMigration("v3_provider_usage_image_tokens") { db in
            try UsageService.addBreakdownColumns(db)
        }
        migrator.registerMigration("v4_provider_usage_request_context") { db in
            try UsageService.addBreakdownColumns(db)
        }
        migrator.registerMigration("v1_team_discussions") { db in
            try TeamDiscussionStore.createSchema(db)
        }
        migrator.registerMigration("v7_note_media_files") { db in
            try NoteStore.createMediaFileSchema(db)
            try NoteStore.createVisualSchema(db)
            try NoteStore.createWorkflowLeaseSchema(db)
            try NoteStore.createSpeakerAnalysisSchema(db)
        }
        migrator.registerMigration("v8_note_media_leases") { db in
            try NoteStore.createMediaFileSchema(db)
        }
        migrator.registerMigration("v4_team_write_directory_identity") { db in
            try db.alter(table: "team_writes") { table in
                table.add(column: "rootDevice", .integer)
                table.add(column: "rootInode", .integer)
            }
        }
        migrator.registerMigration("v4_chat_data_policy") { db in
            try SessionService.addDataPolicyColumn(db)
        }
        migrator.registerMigration("v4_mcp_submission_receipts") { db in
            try MCPServerConfigService.createSubmissionSchema(db)
        }
        // Local undo rights belong to the original workspace and are never imported with artifacts.
        migrator.registerMigration("v4_artifact_edit_receipts") { db in
            try db.create(table: "artifact_edit_receipts") { t in
                t.column("versionID", .text).primaryKey().references("artifact_versions", column: "id", onDelete: .cascade)
                t.column("rootIdentity", .blob).notNull()
                t.column("recoveryID", .text)
                t.column("undone", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v2_task_file_recovery_root_identity") { db in
            if try !db.columns(in: "task_file_recoveries").contains(where: { $0.name == "rootIdentity" }) {
                try db.alter(table: "task_file_recoveries") { $0.add(column: "rootIdentity", .blob) }
            }
        }
        migrator.registerMigration("v1_note_cipher_cleanup") { db in
            try db.execute(sql: "CREATE TABLE note_cipher_cleanup (id INTEGER PRIMARY KEY CHECK(id = 1), generation TEXT NOT NULL)")
        }
        try migrator.migrate(queue)
    }
}
