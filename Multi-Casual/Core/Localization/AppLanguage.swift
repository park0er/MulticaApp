import Foundation

#if canImport(Observation)
import Observation
#endif

#if canImport(SwiftUI)
import SwiftUI
#endif

public enum AppLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case zhHans = "zh-Hans"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "System"
        case .english: return "English"
        case .zhHans: return "中文"
        }
    }

    public var localeIdentifier: String {
        switch self {
        case .system: return Locale.current.identifier
        case .english: return "en"
        case .zhHans: return "zh-Hans"
        }
    }
}

#if canImport(Observation)
@Observable
#endif
@MainActor
public final class AppLanguageSettings {
    public static let defaultsKey = "app_language"

    public var language: AppLanguage {
        didSet {
            userDefaults.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    private let userDefaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        #if DEBUG
        if let rawLanguage = ProcessInfo.processInfo.environment["MULTI_CASUAL_DEBUG_APP_LANGUAGE"],
           let language = AppLanguage(rawValue: rawLanguage) {
            self.language = language
            return
        }
        #endif
        let rawValue = userDefaults.string(forKey: Self.defaultsKey)
        self.language = rawValue.flatMap(AppLanguage.init(rawValue:)) ?? .system
    }
}

public enum AppStrings {
    public static func localized(_ key: String, language: AppLanguage) -> String {
        guard language == .zhHans else { return key }
        if let value = zhHans[key] {
            return value
        }
        if let bundle = Bundle.localizedBundle(for: language) {
            let value = bundle.localizedString(forKey: key, value: key, table: nil)
            if value != key {
                return value
            }
        }
        return key
    }

    /// Pluralized lookup: substitutes `{count}` in the localized template.
    public static func localized(_ key: String, language: AppLanguage, count: Int) -> String {
        localized(key, language: language).replacingOccurrences(of: "{count}", with: "\(count)")
    }

    private static let zhHans: [String: String] = [
        "Account": "账号",
        "Active Tasks": "运行中的任务",
        "Activity": "活动",
        "Add a comment…": "添加评论…",
        "Add Attachment": "添加附件",
        "Add Image": "添加图片",
        "Add Reaction": "添加回应",
        "Add Sub-issue": "添加子 Issue",
        "Agent": "Agent",
        "Agents": "Agents",
        "Agent Activity": "Agent 活动",
        "Agent Transcript": "Agent 记录",
        "Agent Work Details": "Agent 工作详情",
        "Agent queued": "Agent 排队中",
        "Agent running": "Agent 运行中",
        "Agent run": "Agent 运行",
        "Agents Dispatched": "已派出 Agents",
        "All Priorities": "全部优先级",
        "Ascending": "升序",
        "API Tokens": "API 令牌",
        "Archive": "归档",
        "Assignee": "负责人",
        "Autopilots": "自动任务",
        "Backlog": "积压",
        "Blocked": "受阻",
        "Cancel": "取消",
        "Cancel Task": "取消任务",
        "Cancelled": "已取消",
        "Chat": "聊天",
        "Clear Selection": "清除选择",
        "Comments": "评论",
        "HTML Preview Debug": "HTML 预览调试",
        "Comment Actions": "评论操作",
        "Resolve Thread": "解决该讨论",
        "Resolve Thread with Comment": "以此评论解决讨论",
        "Unresolve": "重新打开",
        "Resolved": "已解决",
        "Resolution": "结论",
        "This thread is resolved": "此讨论已解决",
        "N resolved comments": "{count} 条已解决评论",
        "N comments folded": "{count} 条评论",
        "Collapse": "收起",
        "Configure": "配置",
        "Created": "已创建",
        "Default": "默认",
        "Delete": "删除",
        "Descending": "降序",
        "Delete Comment": "删除评论",
        "Delete Issue": "删除 Issue",
        "Done": "完成",
        "Direction": "方向",
        "Due Date": "截止日期",
        "Edit": "编辑",
        "Edit Issue": "编辑 Issue",
        "Error": "错误",
        "Feedback": "反馈",
        "High": "高",
        "In Progress": "进行中",
        "In Review": "评审中",
        "Inbox": "收件箱",
        "Inbox Actions": "收件箱操作",
        "Input": "输入",
        "Issue": "Issue",
        "Issue linked": "已关联 Issue",
        "Issue not found": "未找到 Issue",
        "Issues": "Issues",
        "Idle": "空闲",
        "Labels": "标签",
        "Language": "语言",
        "Latest Progress": "最新进度",
        "Squads": "小队",
        "Squad": "小队",
        "New Squad": "新建小队",
        "Edit Squad": "编辑小队",
        "No Squads": "没有小队",
        "This workspace has no squads yet.": "此工作区还没有小队。",
        "Name": "名称",
        "Description": "描述",
        "Leader": "队长",
        "Select a leader": "选择队长",
        "No agents available. Create an agent first.": "暂无可用 Agent，请先创建 Agent。",
        "Instructions": "指令",
        "Pinned": "置顶",
        "Pin": "置顶",
        "Unpin": "取消置顶",
        "Loading": "加载中",
        "Loading agent activity": "正在加载 Agent 活动",
        "Loading latest progress": "正在加载最新进度",
        "Log Out": "退出登录",
        "Low": "低",
        "Manage Subscribers": "管理订阅者",
        "Mark All Read": "全部标为已读",
        "Members": "成员",
        "Medium": "中",
        "Mention Agent": "提及 Agent",
        "Move Down": "下移",
        "Move Up": "上移",
        "Move to Status": "移动到状态",
        "My Agents": "我的 Agents",
        "My Issues": "我的 Issues",
        "New Issue": "新建 Issue",
        "No Active Tasks": "没有运行中的任务",
        "No Activity": "没有活动",
        "No Agent Activity": "没有 Agent 活动",
        "No Comments": "没有评论",
        "No Messages": "没有消息",
        "No Priority": "无优先级",
        "No Project": "无项目",
        "No Agent Issues": "没有 Agent Issues",
        "No Assigned Issues": "没有分配给我的 Issues",
        "No Created Issues": "没有我创建的 Issues",
        "No Issues": "没有 Issues",
        "No sub-issues": "没有子 Issue",
        "No subscribers": "没有订阅者",
        "No Usage": "没有用量",
        "No workspace": "没有工作区",
        "Notifications": "通知",
        "Number": "编号",
        "Offline": "离线",
        "Online": "在线",
        "OK": "确定",
        "Open": "打开",
        "Output": "输出",
        "Oldest First": "最旧优先",
        "Priority": "优先级",
        "Preferences": "偏好设置",
        "Project": "项目",
        "Projects": "项目",
        "Queued": "排队中",
        "Read": "已读",
        "Reply": "回复",
        "Result": "结果",
        "Retry": "重试",
        "Runtimes": "运行时",
        "Save": "保存",
        "Search issues": "搜索 Issues",
        "Search projects": "搜索项目",
        "Settings": "设置",
        "Skills": "Skills",
        "Newest First": "最新优先",
        "Sort": "排序",
        "Sort by": "排序维度",
        "Status": "状态",
        "Sub-issues": "子 Issues",
        "There are no issues in this workspace.": "此工作区没有 Issues。",
        "There are no projects in this workspace.": "此工作区没有项目。",
        "Subscribers": "订阅者",
        "System": "跟随系统",
        "Thinking": "思考",
        "Tool Input": "工具输入",
        "Tool Output": "工具输出",
        "Tool Use": "工具调用",
        "Todo": "待办",
        "Transcript Unavailable": "记录不可用",
        "Unread": "未读",
        "Unknown": "未知",
        "Unstable": "不稳定",
        "Upload failed.": "上传失败。",
        "Updated": "已更新",
        "Urgent": "紧急",
        "Usage": "用量",
        "Workspace": "工作区",
        "Workspace Details": "工作区详情",
        "Workspaces": "工作区",
        "Waiting for agent updates": "正在等待 Agent 更新",
        "Working": "工作中",
        "events": "条事件",
        "1 event": "1 条事件",
    ]
}

private extension Bundle {
    static func localizedBundle(for language: AppLanguage) -> Bundle? {
        guard language == .zhHans,
              let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj")
        else {
            return nil
        }
        return Bundle(path: path)
    }
}

#if canImport(SwiftUI)
private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue: AppLanguage = .system
}

public extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}
#endif
