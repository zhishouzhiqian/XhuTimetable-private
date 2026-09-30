import UIKit
import UniformTypeIdentifiers

/// 仅个人组件检查包开放；原始安全素材从文件导入，不随源码或 CI 上传。
final class LaundryComponentCheckViewController: UIViewController, UIDocumentPickerDelegate {
    // SDK 为进程单例。关闭页面后仍保留执行状态，防止重新导入或并发检查。
    private static var importedPath: String?
    private static var attempted = false
    private static var lastResult: String?
    private let result: () -> Void
    private let importButton = UIButton(type: .system)
    private let runButton = UIButton(type: .system)
    private let output = UILabel()
    private var resourcePath: String?
    private var running = false
    private var closed = false
    private var timeout: DispatchWorkItem?

    init(result: @escaping () -> Void) {
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
        resourcePath = Self.importedPath
        importButton.isEnabled = !Self.attempted
        runButton.isEnabled = resourcePath != nil && !Self.attempted
        output.text = Self.lastResult ?? (resourcePath == nil ? "等待导入检查资源。" : "检查资源已导入。可以开始组件检查。")
        output.font = .preferredFont(forTextStyle: .body)
        output.adjustsFontForContentSizeCategory = true
        output.numberOfLines = 0
        let column = UIStackView(arrangedSubviews: [close, title, introduction, importButton, runButton, output])
        column.axis = .vertical
        column.spacing = 16
        column.translatesAutoresizingMaskIntoConstraints = false
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        scroll.addSubview(column)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            column.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            column.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
            importButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            runButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
    }

    @objc private func importResources() {
        guard !Self.attempted, !running else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard !Self.attempted, !running, let file = urls.first else { return }
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
        guard !Self.attempted, !running, let path = resourcePath else { return }
        Self.attempted = true
        running = true
        importButton.isEnabled = false
        runButton.isEnabled = false
        output.text = "正在检查 SDK 与当次安全字段…"
        Self.lastResult = "组件检查已开始。如需再次检查，请彻底关闭应用后重新打开。"
        let watchdog = DispatchWorkItem { [weak self] in
            guard let self, self.running, !self.closed else { return }
            Self.lastResult = "组件检查超过 45 秒（错误码 PROBE_TIMEOUT）。请保留此结果，重新启动应用后再试。"
            self.output.text = Self.lastResult
        }
        timeout = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: watchdog)
        CampusComponentProbe.run(atResourcePath: path) { [weak self] rows in
            Self.lastResult = rows.map { "\($0["step"] ?? "检查")：\($0["result"] ?? "未知")" }.joined(separator: "\n\n")
                + "\n\n如需再次检查，请彻底关闭应用后重新打开。"
            guard let self, !self.closed else { return }
            self.timeout?.cancel()
            self.running = false
            self.output.text = Self.lastResult
        }
    }

    @objc private func closePage() {
        guard !closed else { return }
        closed = true
        timeout?.cancel()
        result()
    }
    deinit { timeout?.cancel() }
    private enum ImportFailure: Error { case invalid }
}
