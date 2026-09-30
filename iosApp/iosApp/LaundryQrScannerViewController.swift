import AVFoundation
import UIKit

/// 仅由登录成功后的洗衣入口展示；识别结果交给共享二维码策略校验。
final class LaundryQrScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "vip.mystery0.xhu.timetable.laundry.camera")
    private let preview = AVCaptureVideoPreviewLayer()
    private let result: (String?, String?) -> Void
    private var completed = false // 主线程访问
    private var stopped = false // captureQueue 访问

    init(result: @escaping (String?, String?) -> Void) {
        self.result = result
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    required init?(coder: NSCoder) { fatalError("请使用扫码入口创建页面") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.session = session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)

        let cancel = UIButton(type: .system)
        cancel.setTitle("取消", for: .normal)
        cancel.tintColor = .white
        cancel.addTarget(self, action: #selector(cancelScan), for: .touchUpInside)
        cancel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancel)
        let instruction = UILabel()
        instruction.text = "请对准洗衣机二维码"
        instruction.textColor = .white
        instruction.font = .preferredFont(forTextStyle: .body)
        instruction.adjustsFontForContentSizeCategory = true
        instruction.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instruction)
        NSLayoutConstraint.activate([
            cancel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            cancel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            instruction.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            instruction.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -32)
        ])
        authorizeCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
        if let connection = preview.connection, connection.isVideoOrientationSupported,
           let orientation = view.window?.windowScene?.interfaceOrientation {
            switch orientation {
            case .landscapeLeft: connection.videoOrientation = .landscapeLeft
            case .landscapeRight: connection.videoOrientation = .landscapeRight
            case .portraitUpsideDown: connection.videoOrientation = .portraitUpsideDown
            default: connection.videoOrientation = .portrait
            }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        finish(contents: nil, error: nil)
    }

    private func authorizeCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self, !self.completed else { return }
                    if granted { self.configureCamera() }
                    else { self.finish(contents: nil, error: "请在系统设置中允许访问相机。") }
                }
            }
        default: finish(contents: nil, error: "请在系统设置中允许访问相机。")
        }
    }

    private func configureCamera() {
        captureQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            do {
                guard let device = AVCaptureDevice.default(for: .video) else {
                    throw CameraFailure.unavailable
                }
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureMetadataOutput()
                self.session.beginConfiguration()
                defer { self.session.commitConfiguration() }
                guard self.session.canAddInput(input), self.session.canAddOutput(output) else {
                    throw CameraFailure.unavailable
                }
                self.session.addInput(input)
                self.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    throw CameraFailure.unavailable
                }
                output.metadataObjectTypes = [.qr]
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.finish(contents: nil, error: "暂时无法打开相机，请重试。")
                }
                return
            }
            // startRunning 不能在主线程调用，也不能在配置事务内调用。
            self.session.startRunning()
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
            .first(where: { $0.type == .qr })?.stringValue else { return }
        finish(contents: code, error: nil)
    }

    @objc private func cancelScan() { finish(contents: nil, error: nil) }

    private func finish(contents: String?, error: String?) {
        guard !completed else { return }
        completed = true
        captureQueue.async { [self] in
            stopped = true
            if session.isRunning { session.stopRunning() }
        }
        // 由桥接宿主统一关闭页面，取消和结果回调不会重复 dismiss。
        result(contents, error)
    }

    private enum CameraFailure: Error { case unavailable }
}
