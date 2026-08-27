import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview that reports the first QR code it decodes.
struct QRScannerView: UIViewControllerRepresentable {
    let isPaused: Bool
    let onCode: (String) -> Void
    let onFailure: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: QRScannerViewController, context: Context) {
        controller.setPaused(isPaused)
    }
}

final class QRScannerViewController: UIViewController {
    var onCode: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.k.signstr.scanner")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var isPaused = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        requestAccessAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning {
                captureSession.stopRunning()
            }
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
    }

    private func requestAccessAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self else { return }
                    if granted {
                        self.configureSession()
                    } else {
                        self.onFailure?("Signstr needs camera access to scan a pairing code. Enable it in Settings.")
                    }
                }
            }
        case .denied, .restricted:
            onFailure?("Camera access is turned off. Enable it for Signstr in Settings.")
        @unknown default:
            onFailure?("Camera access is unavailable.")
        }
    }

    private func configureSession() {
        guard !isConfigured else { return }
        isConfigured = true

        guard
            let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            captureSession.canAddInput(input)
        else {
            onFailure?("This device has no camera available for scanning.")
            return
        }

        let output = AVCaptureMetadataOutput()
        captureSession.beginConfiguration()
        captureSession.addInput(input)
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            onFailure?("The camera could not be prepared for scanning.")
            return
        }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
        captureSession.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.insertSublayer(layer, at: 0)
        previewLayer = layer

        sessionQueue.async { [captureSession] in
            captureSession.startRunning()
        }
    }
}

extension QRScannerViewController: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !isPaused else { return }
        guard
            let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            object.type == .qr,
            let payload = object.stringValue
        else {
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onCode?(payload)
    }
}
