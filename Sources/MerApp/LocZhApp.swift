import Foundation
import MerCore

/// Simplified Chinese strings for the app's own UI. Keys are the English source strings.
enum LocZhApp {
    static let table: [String: String] = [
        // menu bar & app menu
        "Mer Settings": "Mer 设置", "Open Mer": "打开 Mer", "Convert Files…": "转换文件…",
        "Convert Finder Selection": "转换访达中选中的文件", "Drag Wheel": "拖拽转盘", "Test Wheel": "测试转盘",
        "Open Drag Log": "打开拖拽日志", "Settings…": "设置…", "Quit Mer": "退出 Mer",
        "Edit": "编辑", "Cut": "剪切", "Copy": "拷贝", "Paste": "粘贴", "Select All": "全选", "Window": "窗口", "Close": "关闭",
        "Choose": "选取", "Select a file in Finder first": "请先在访达中选中文件", "Convert with Mer": "用 Mer 转换",
        "Not running from a packaged app — build with Scripts/bundle.sh.": "当前不是打包后的应用——请先用 Scripts/bundle.sh 构建。",
        "Installed at ~/.local/bin/mer (make sure it is on your PATH).": "已安装到 ~/.local/bin/mer（请确认它在 PATH 中）。",
        "Copied to clipboard": "已拷贝到剪贴板",

        // modifier keys / layers
        "Off": "关闭", "Convert": "转换", "Tools": "工具", "Actions": "文件操作",

        // file actions
        "AirDrop": "隔空投送", "Float": "悬浮", "Move…": "移动…", "Copy Path": "拷贝路径", "Terminal": "终端", "Reveal": "显示",
        "Move Here": "移到这里", "Path copied": "路径已拷贝", "Drag me into any app · double-click to open": "拖到任意应用中 · 双击打开",
        "Copied %@": "已拷贝 %@", "Moved %d item to %@": "已将 %d 个项目移到 %@", "Moved %d items to %@": "已将 %d 个项目移到 %@",

        // HUD / jobs
        "%d files": "%d 个文件", "Reveal in Finder": "在访达中显示", "Cancel": "取消",

        // palette
        "All": "全部", "Search formats and tools": "搜索格式和工具", "Nothing matches": "没有匹配项", "Tool": "工具",
        "Back": "返回", "Run": "运行", "Dismiss": "关闭", "navigate": "选择", "run": "运行", "switch": "切换", "close": "关闭",

        // wheel
        "No conversions for this file": "此文件没有可用的转换", "No tools for this file": "此文件没有可用的工具", "More": "更多",

        // main window
        "Offline file converter": "离线文件转换器", "Release to choose a format": "松开以选择格式", "Drop files here": "把文件拖到这里",
        "Or hold ⇧ while dragging a file anywhere on your Mac to open the wheel.": "也可以在 Mac 上任意位置拖动文件时按住 ⇧ 打开转盘。",
        "Choose Files…": "选择文件…", "conversions": "个转换", "tools": "个工具", "engines": "个引擎", "Settings": "设置",
        "Recent": "最近", "Clear": "清除", "Converted files appear here": "转换后的文件会显示在这里",

        // settings: tabs & cards
        "General": "通用", "Wheel": "转盘", "Engines": "引擎", "Recipes": "配方",
        "Output": "输出", "Save results": "保存位置", "Next to the original": "与原文件在同一文件夹", "In a specific folder": "指定文件夹",
        "No folder chosen": "未选择文件夹", "Choose…": "选择…", "Move originals to Trash": "将原文件移到废纸篓",
        "After a successful conversion": "转换成功后", "Reveal results in Finder": "完成后在访达中显示结果",
        "System": "系统", "Launch at login": "登录时启动", "Command palette": "命令面板",
        "Opens for the current Finder selection": "对访达中当前选中的文件打开", "Command-line tool": "命令行工具",
        "Use Mer from Terminal as `mer`": "在终端中使用 `mer` 命令", "Install `mer`": "安装 `mer`",
        "Language": "语言", "Follow System": "跟随系统", "Interface language": "界面语言",
        "Drag wheel": "拖拽转盘", "Show the wheel while dragging files": "拖动文件时显示转盘",
        "Hold a key after you start dragging": "开始拖动后按住一个按键", "Keys": "按键", "Conversions": "转换",
        "Turn the file into another format": "把文件转成另一种格式", "File tools": "文件工具",
        "Compress, crop, trim, merge …": "压缩、裁剪、剪切、合并…", "File actions": "文件操作",
        "AirDrop, float, copy, move …": "隔空投送、悬浮、拷贝、移动…", "How it works": "使用方法",
        "Start dragging a file from Finder, then press a key. The wheel stays open until you drop on a slice or let go. Hover “More” to page through long lists, and press another key to switch layers.":
            "在访达（或任何地方）开始拖动文件，然后按下一个按键。转盘会一直保持打开，直到你把文件放到某个扇区上或松开鼠标。把光标停在“更多”上可以翻页，再按另一个按键可以切换层。",
        "Mer converts the common formats on its own. Optional engines unlock many more and are detected automatically.":
            "Mer 本身就能转换常见格式。可选引擎能解锁更多格式，并且会被自动检测。",
        "Installing engines needs Homebrew (brew.sh).": "安装引擎需要 Homebrew（brew.sh）。",
        "Re-scan": "重新检测", "Installed": "已安装", "Install": "安装",
        "Recipes teach Mer new conversions by calling any command-line tool. Drop a `.json` file in the Recipes folder and press Reload.":
            "配方可以让 Mer 通过调用任意命令行工具获得新的转换能力。把 `.json` 文件放进配方文件夹，然后点“重新载入”。",
        "Example": "示例", "Placeholders: {tool} {input} {output} {inputs} {name} {dir} {tmpdir} {param:key}":
            "占位符：{tool} {input} {output} {inputs} {name} {dir} {tmpdir} {param:key}",
        "%d custom recipe loaded": "已载入 %d 个自定义配方", "%d custom recipes loaded": "已载入 %d 个自定义配方",
        "Key test": "按键检测", "Hold ⇧, ⌘ or ⌃ to check that Mer can see it": "按住 ⇧、⌘ 或 ⌃，检查 Mer 能否检测到",
        "Opens the “%@” wheel": "会打开“%@”转盘", "No wheel key is held": "没有按住转盘按键",
        "Create Example": "创建示例", "Open Folder": "打开文件夹", "Reload": "重新载入",
    ]
}
