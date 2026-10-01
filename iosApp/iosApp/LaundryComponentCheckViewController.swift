import UIKit
import UniformTypeIdentifiers
import CryptoKit

/// 仅个人组件检查包开放；原始安全素材从文件导入，不随源码或 CI 上传。
final class LaundryComponentCheckViewController: UIViewController, UIDocumentPickerDelegate {
    // SDK 为进程单例。关闭页面后仍保留执行状态，防止重新导入或并发检查。
    private static var importedPath: String?
    private static var attempted = false
    private static var lastResult: String?
    private static var isRunning = false
    private static var timeout: DispatchWorkItem?
    private static let reportChanged = Notification.Name("CampusComponentProbeReportChanged")
    private let result: () -> Void
    private let showsCloseButton: Bool
    private let importButton = UIButton(type: .system)
    private let runButton = UIButton(type: .system)
    private let output = UILabel()
    private let appKeyField = UITextField()
    private let copyButton = UIButton(type: .system)
    private var resourcePath: String?
    private var closed = false

    init(showsCloseButton: Bool = true, result: @escaping () -> Void) {
        self.showsCloseButton = showsCloseButton
        self.result = result
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    required init?(coder: NSCoder) { fatalError("请从组件检查入口打开") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let close = UIButton(type: .system)
        close.setTitle("返回", for: .normal)
        close.isHidden = !showsCloseButton
        close.addTarget(self, action: #selector(closePage), for: .touchUpInside)
        let title = UILabel()
        title.text = "iOS 洗衣组件检查"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        let introduction = UILabel()
        introduction.text = "先导入检查资源，再点击开始检查。\n此检查验证候选 SDK 的初始化与本地签名字段生成，不能证明校园服务器已接受签名。不会登录、下单或付款。"
        introduction.font = .preferredFont(forTextStyle: .body)
        introduction.adjustsFontForContentSizeCategory = true
        introduction.numberOfLines = 0
        importButton.setTitle("导入检查资源", for: .normal)
        importButton.addTarget(self, action: #selector(importResources), for: .touchUpInside)
        runButton.setTitle("开始组件检查", for: .normal)
        runButton.addTarget(self, action: #selector(runCheck), for: .touchUpInside)
        appKeyField.placeholder = "可选：抓包中的 AppKey"
        appKeyField.borderStyle = .roundedRect
        appKeyField.keyboardType = .asciiCapable
        appKeyField.autocorrectionType = .no
        appKeyField.autocapitalizationType = .none
        appKeyField.font = .preferredFont(forTextStyle: .body)
        appKeyField.adjustsFontForContentSizeCategory = true
        appKeyField.accessibilityLabel = "可选 AppKey，留空时从资源读取"
        let hint = UILabel()
        hint.text = "AppKey 可留空。只有配置读取为空且已知抓包中的 AppKey 时才填写；不要填写 Cookie、token 或验证码。"
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.adjustsFontForContentSizeCategory = true
        copyButton.setTitle("复制检查结果", for: .normal)
        copyButton.addTarget(self, action: #selector(copyReport), for: .touchUpInside)
        if Self.importedPath == nil,
           let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let folder = base.appendingPathComponent("CampusComponentProbe.bundle")
            if FileManager.default.fileExists(atPath: folder.appendingPathComponent("probe-manifest.plist").path) {
                Self.importedPath = folder.path
            }
        }
        resourcePath = Self.importedPath
        importButton.isEnabled = !Self.attempted
        runButton.isEnabled = resourcePath != nil && !Self.attempted
        output.text = Self.lastResult ?? (resourcePath == nil ? "等待导入检查资源。" : "检查资源已导入。可以开始组件检查。")
        output.font = .preferredFont(forTextStyle: .body)
        output.adjustsFontForContentSizeCategory = true
        output.numberOfLines = 0
        let column = UIStackView(arrangedSubviews: [close, title, introduction, importButton, appKeyField, hint, runButton, copyButton, output])
        column.axis = .vertical
        column.spacing = 16
        column.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.keyboardDismissMode = .onDrag
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            importButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            runButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refreshReport), name: Self.reportChanged, object: nil)
        refreshReport()
    }

    @objc private func importResources() {
        guard !Self.attempted, !Self.isRunning else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !Self.attempted, !Self.isRunning, let file = urls.first else { return }
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        do {
            let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard bytes > 0, bytes <= 200_000 else { throw ImportFailure.invalid }
            let data = try Data(contentsOf: file)
            guard data.count <= 200_000,
                  let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  document["format"] as? String == "campus-ios-component-resources",
                  document["version"] as? Int == 1,
                  let resources = document["resources"] as? [String: String],
                  Set(resources.keys) == Set(["yw_1222.jpg", "yw_1222_mwua.jpg"]) else {
                throw ImportFailure.invalid
            }
            var decoded: [String: Data] = [:]
            for (name, value) in resources {
                guard let raw = Data(base64Encoded: value), !raw.isEmpty, raw.count <= 65536 else {
                    throw ImportFailure.invalid
                }
                decoded[name] = raw
            }
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            var folder = base.appendingPathComponent("CampusComponentProbe.bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            // 仅独立资源目录，不更改主应用 Bundle ID 或伪造原应用身份。
            let info: [String: String] = ["CFBundleIdentifier": "vip.mystery0.xhu.timetable.component-resources",
                "CFBundleName": "CampusComponentProbe", "CFBundlePackageType": "BNDL"]
            let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
            try plist.write(to: folder.appendingPathComponent("Info.plist"), options: [.atomic, .completeFileProtection])
            for (name, raw) in decoded {
                try raw.write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
            }
            let hashes = decoded.mapValues { raw in SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined() }
            let manifest = try PropertyListSerialization.data(fromPropertyList: hashes, format: .binary, options: 0)
            try manifest.write(to: folder.appendingPathComponent("probe-manifest.plist"), options: [.atomic, .completeFileProtection])
            resourcePath = folder.path
            Self.importedPath = folder.path
            output.text = "检查资源已导入。可以开始组件检查。"
            runButton.isEnabled = true
        } catch {
            resourcePath = nil
            Self.importedPath = nil
            runButton.isEnabled = false
            output.text = "资源文件无效或无法读取，请导入提供的检查资源 JSON 文件。"
        }
    }

    @objc private func runCheck() {
        guard !Self.attempted, !Self.isRunning, let path = resourcePath else { return }
        view.endEditing(true)
        let key = (appKeyField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.isEmpty || key.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) != nil else {
            output.text = "AppKey 格式不正确；也可以留空后检查。"
            return
        }
        Self.attempted = true
        Self.isRunning = true
        importButton.isEnabled = false
        runButton.isEnabled = false
        output.text = "正在检查 SDK 与当次安全字段…"
        Self.lastResult = "组件检查已开始。如需再次检查，请彻底关闭应用后重新打开。"
        let watchdog = DispatchWorkItem {
            guard Self.isRunning else { return }
            Self.lastResult = (Self.lastResult ?? "") + "\n\n检查超过 45 秒（PROBE_TIMEOUT）。以上保留最后执行步骤；请复制结果，重启应用后再试。"
            NotificationCenter.default.post(name: Self.reportChanged, object: nil)
        }
        Self.timeout = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: watchdog)
        CampusComponentProbe.run(atResourcePath: path, appKeyHint: key.isEmpty ? nil : key, progress: { rows in
            Self.updateReport(rows, completed: false)
        }, completion: { rows in
            Self.timeout?.cancel()
            Self.timeout = nil
            Self.isRunning = false
            Self.updateReport(rows, completed: true)
        })
        refreshReport()
    }

    private static func updateReport(_ rows: [[String: String]], completed: Bool) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知"
        let bundleID = Bundle.main.bundleIdentifier ?? "未知"
        let revision = Bundle.main.object(forInfoDictionaryKey: "CampusProbeRevision") as? String
        lastResult = "检查版本：\(version)\n应用：\(bundleID)\n\n"
            + (revision.map { "检查修订：\($0)\n\n" } ?? "")
            + rows.map { "\($0["step"] ?? "检查")：\($0["result"] ?? "未知")" }.joined(separator: "\n\n")
            + (completed ? "\n\n如需再次检查，请彻底关闭应用后重新打开。" : "")
        NotificationCenter.default.post(name: reportChanged, object: nil)
    }

    @objc private func refreshReport() {
        if let report = Self.lastResult { output.text = report }
        copyButton.isEnabled = Self.lastResult != nil
        importButton.isEnabled = !Self.attempted
        appKeyField.isEnabled = !Self.attempted
        runButton.isEnabled = resourcePath != nil && !Self.attempted
    }

    @objc private func copyReport() {
        guard let report = Self.lastResult else { return }
        // 报告只含步骤、状态和数值错误码，不包含输入 AppKey 或安全字段。
        UIPasteboard.general.string = report
        copyButton.setTitle("已复制检查结果", for: .normal)
    }

    @objc private func closePage() {
        guard !closed else { return }
        closed = true
        result()
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    private enum ImportFailure: Error { case invalid }
}
