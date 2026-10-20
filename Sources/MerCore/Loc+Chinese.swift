import Foundation

extension Loc {
    /// Regex rules for messages that embed names; `$1…` are filled with the (translated, if known) captures.
    static let patterns: [(String, String)] = [
        ("^via (.+)$", "通过 $1"),
        ("^Cannot read (.+)$", "无法读取 $1"),
        ("^Cannot write (.+)$", "无法写入 $1"),
        ("^Cannot open (.+)$", "无法打开 $1"),
        ("^Failed to write (.+)$", "写入失败：$1"),
        ("^Unsupported: (.+)$", "不支持：$1"),
        ("^Required tool not installed: (.+)$", "未安装所需工具：$1"),
        ("^(.+) is required$", "$1 为必填项"),
        ("^(.+) must be a number of seconds$", "$1 必须是以秒为单位的数字"),
        ("^(.+) produced no (.+) file$", "$1 没有生成 $2 文件"),
        ("^(.+) finished but no output was created$", "$1 已结束，但没有生成输出文件"),
        ("^(.+) exited with (\\d+)(.*)$", "$1 异常退出（状态码 $2）$3"),
        ("^Installed, but (.+) was not found$", "已安装，但找不到 $1"),
        ("^Preset (.+) is not available for this file$", "此文件不支持预设 $1"),
        ("^This file cannot be exported as (.+)$", "此文件无法导出为 $1"),
        ("^Compress to (.+)$", "压缩为 $1"),
    ]

    static let zhEngine: [String: String] = [
        // categories
        "Image": "图片", "Video": "视频", "Audio": "音频", "Document": "文档", "PDF": "PDF", "Spreadsheet": "表格",
        "Slides": "幻灯片", "Subtitle": "字幕", "Archive": "压缩包", "File": "文件",

        // action titles
        "Trim…": "裁剪…", "Merge into One Track": "合并为一条音轨",
        "Remove PDF Password…": "移除 PDF 密码…", "Protect with Password…": "用密码保护…",
        "Resize…": "调整大小…", "Resize 50%": "缩小到 50%", "Compress": "压缩", "Remove Metadata": "移除元数据",
        "Combine into One PDF": "合并为一个 PDF", "TXT (OCR)": "TXT（文字识别）",
        "Searchable PDF (OCR)": "可搜索 PDF（文字识别）", "Make Searchable (OCR)": "生成可搜索 PDF（文字识别）",
        "Merge PDFs": "合并 PDF", "Split into Pages": "拆分为单页", "Extract Pages…": "提取页面…",
        "Rotate 90° Right": "向右旋转 90°", "Rotate 90° Left": "向左旋转 90°", "Rotate 180°": "旋转 180°",
        "Flip Horizontal": "水平翻转", "Flip Vertical": "垂直翻转",
        "Crop Square (1:1)": "裁剪为正方形 (1:1)", "Crop 16:9": "裁剪为 16:9", "Crop 4:3": "裁剪为 4:3", "Crop 3:2": "裁剪为 3:2",
        "Compress PDF": "压缩 PDF", "Extract": "解压",
        "Compress to ZIP": "压缩为 ZIP", "Compress to TAR.GZ": "压缩为 TAR.GZ", "Compress to TAR": "压缩为 TAR",
        "Zip Together": "打包成一个 ZIP",
        "Remove Audio": "移除音频", "Merge Videos": "合并视频", "Save Frame as JPG…": "保存画面为 JPG…",
        "Compress to 720p": "压缩到 720p", "Compress to 480p": "压缩到 480p", "Resize to 1080p": "缩放到 1080p",
        "Compress (Smart)": "智能压缩", "Trim (Lossless)…": "无损裁剪…", "Normalise Loudness": "统一音量",
        "M4A (AAC)": "M4A (AAC)", "MP4 (HEVC)": "MP4 (HEVC)",

        // subtitles
        "Cut by start and end time (seconds)": "按起止时间裁剪（秒）",
        "via Ghostscript (vector)": "通过 Ghostscript（保持矢量）", "via librsvg (vector)": "通过 librsvg（保持矢量）",
        "16–256 px icon": "16–256 像素图标", "Longest side in pixels": "按最长边的像素数",
        "Smaller file, same dimensions": "文件更小，尺寸不变", "EXIF, GPS and camera info": "EXIF、GPS 和相机信息",
        "Recognise text in the picture": "识别图片中的文字", "Picture + invisible text layer": "图片 + 隐藏文字层",
        "Adds a text layer to scanned PDFs": "为扫描版 PDF 添加文字层",
        "One image per slide, via Keynote": "每页幻灯片一张图，通过 Keynote", "One image per page": "每页一张图",
        "Text only — layout is not preserved": "仅文字，不保留版式", "e.g. 1-3, 5, 8-10": "例如 1-3, 5, 8-10",
        "Downsamples embedded images": "降低内嵌图片的分辨率", "ZIP, TAR, GZ, BZ2, XZ, 7Z, RAR": "ZIP、TAR、GZ、BZ2、XZ、7Z、RAR",
        "Grab a still at a given second": "截取指定秒数的画面", "Keeps quality, format unchanged": "保持画质，格式不变",

        // parameter labels
        "Start (s)": "开始（秒）", "Password (leave empty if none)": "密码（没有就留空）", "End (s, 0 = until the end)": "结束（秒，0 = 到结尾）", "Password": "密码",
        "Start (hh:mm:ss or seconds)": "开始（时:分:秒 或 秒数）", "End (hh:mm:ss or seconds)": "结束（时:分:秒 或 秒数）",
        "Longest side (px)": "最长边（像素）", "Quality (1–100)": "质量（1–100）", "Pages": "页码",
        "Width (px)": "宽度（像素）", "Frames per second": "每秒帧数", "Time (s)": "时间（秒）",

        // optional engines (Settings → Engines)
        "MKV, WebM, AVI, WMV, FLV, MP3, OGG, Opus, WMA, lossless trim, loudness normalise":
            "MKV、WebM、AVI、WMV、FLV、MP3、OGG、Opus、WMA，无损裁剪，统一音量",
        "Markdown / DOCX / EPUB / HTML / ODT / LaTeX / RST in every direction":
            "Markdown / DOCX / EPUB / HTML / ODT / LaTeX / RST 之间任意互转",
        "PPT/PPTX/ODP/XLS/DOC → PDF and back, PPTX → images": "PPT/PPTX/ODP/XLS/DOC 与 PDF 互转，PPTX 转图片",
        "SVG input, ICO, PSD, JPEG XL and more image formats": "SVG 输入、ICO、PSD、JPEG XL 等更多图片格式",
        "Stronger PDF compression": "更强的 PDF 压缩", "PDF encrypt / decrypt / repair": "PDF 加密 / 解密 / 修复",

        // messages
        "Invalid time range": "无效的时间范围", "Empty table": "表格为空", "JSON must be an array of objects": "JSON 必须是对象数组",
        "No worksheet found in XLSX": "XLSX 中没有找到工作表", "The document has no text": "文档中没有文字",
        "textutil produced no output": "textutil 没有生成输出", "Cannot create PDF": "无法创建 PDF",
        "Size must be a positive number of pixels": "尺寸必须是正整数像素", "Quality must be a number from 1 to 100": "质量必须是 1 到 100 的数字",
        "Image decode failed": "图片解码失败", "Cannot render SVG": "无法渲染 SVG", "PDF page failed": "PDF 页面生成失败",
        "Cannot write PDF": "无法写入 PDF", "No writable format": "没有可写入的格式",
        "No text found in this image": "这张图片中没有识别到文字", "Cannot open PDF": "无法打开 PDF", "Empty PDF": "PDF 为空",
        "No text found in this PDF": "这个 PDF 中没有识别到文字", "PDF has a single page": "PDF 只有一页",
        "No valid pages in range": "页码范围内没有有效页面", "PDF has no pages": "PDF 没有页面",
        "Already optimised — compression would not make it smaller": "已经是最优——再压缩也不会更小",
        "Cannot open PDF or Quartz filter": "无法打开 PDF 或 Quartz 滤镜",
        "This video has no audio track": "这个视频没有音轨", "No video track": "没有视频轨道", "Empty video": "视频为空",
        "Cannot create GIF": "无法创建 GIF", "GIF encoding failed": "GIF 编码失败", "Cannot write JPG": "无法写入 JPG",
        "Homebrew is not installed (see brew.sh)": "未安装 Homebrew（见 brew.sh）",
        "Waiting…": "等待中…", "Cancelled": "已取消", "Starting…": "正在开始…",
        "Password is required": "密码为必填项",
    ]
}
