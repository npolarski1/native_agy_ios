import SwiftUI

#if canImport(UIKit) && canImport(AVFoundation)
import AVFoundation
import UIKit

/// Native iOS camera QR code scanner with graceful simulator & permission-denied fallbacks.
struct QRScannerView: View {
    let onCodeScanned: (String) -> Void
    @State private var cameraPermissionDenied = false
    @State private var scannerError: String?
    @State private var isTorchEnabled = false
    @State private var manualURIText = ""

    var body: some View {
        #if targetEnvironment(simulator)
        simulatorFallbackView
        #else
        ZStack {
            if cameraPermissionDenied {
                permissionDeniedView
            } else if let scannerError {
                errorView(message: scannerError)
            } else {
                QRScannerRepresentable(
                    isTorchEnabled: $isTorchEnabled,
                    onCodeScanned: onCodeScanned,
                    onPermissionDenied: { cameraPermissionDenied = true },
                    onError: { scannerError = $0 }
                )
                .ignoresSafeArea()

                scannerOverlay
            }
        }
        #endif
    }

    private var scannerOverlay: some View {
        VStack(spacing: 20) {
            Spacer()

            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [.indigo, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
                .frame(width: 240, height: 240)
                .background(Color.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .indigo.opacity(0.45), radius: 14)

            Text("Point camera at the bridge QR code")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())

            Spacer()

            Button {
                isTorchEnabled.toggle()
            } label: {
                Label(isTorchEnabled ? "Torch On" : "Torch Off", systemImage: isTorchEnabled ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .tint(.white)
            .padding(.bottom, 24)
        }
        .padding()
    }

    private var permissionDeniedView: some View {
        ContentUnavailableView {
            Label("Camera Access Needed", systemImage: "camera.fill")
        } description: {
            Text("Enable Camera access in Settings to scan your workstation's pairing QR code, or switch to LAN / Manual pairing.")
        } actions: {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func errorView(message: String) -> some View {
        ContentUnavailableView {
            Label("Camera Unavailable", systemImage: "video.slash")
        } description: {
            Text(message)
        }
    }

    private var simulatorFallbackView: some View {
        VStack(spacing: 16) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 54))
                .foregroundStyle(.indigo)

            Text("Camera Scanner Unavailable in Simulator")
                .font(.headline)

            Text("Paste an agymon://pair URI printed by `antigravity-bridge pair-qr` to test QR pairing in Simulator.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            TextField("agymon://pair?url=...&token=...&name=...", text: $manualURIText)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.footnote.monospaced())
                .padding(.horizontal)

            Button("Parse Pairing URI") {
                let trimmed = manualURIText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    onCodeScanned(trimmed)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(manualURIText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding()
    }
}

struct QRScannerRepresentable: UIViewControllerRepresentable {
    @Binding var isTorchEnabled: Bool
    let onCodeScanned: (String) -> Void
    let onPermissionDenied: () -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCodeScanned = onCodeScanned
        controller.onPermissionDenied = onPermissionDenied
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        uiViewController.setTorch(enabled: isTorchEnabled)
    }
}

private final class CaptureSessionBox: @unchecked Sendable {
    let session = AVCaptureSession()
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?
    var onError: ((String) -> Void)?

    private let sessionBox = CaptureSessionBox()
    private let sessionQueue = DispatchQueue(label: "com.antigravity.monitor.qr.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var hasEmittedCode = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        checkPermissionAndConfigure()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasEmittedCode = false
        startSessionIfNeeded()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    func setTorch(enabled: Bool) {
        sessionQueue.async {
            guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
            do {
                try device.lockForConfiguration()
                device.torchMode = enabled ? .on : .off
                device.unlockForConfiguration()
            } catch {
                // Ignore torch toggle failures on unsupported hardware.
            }
        }
    }

    private func checkPermissionAndConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor [weak self] in
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.onPermissionDenied?()
                    }
                }
            }
        case .denied, .restricted:
            onPermissionDenied?()
        @unknown default:
            onPermissionDenied?()
        }
    }

    private func configureSession() {
        guard !isConfigured else {
            startSessionIfNeeded()
            return
        }

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            onError?("No video capture device available on this device.")
            return
        }

        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            onError?("Could not access camera input: \(error.localizedDescription)")
            return
        }

        let captureSession = sessionBox.session
        captureSession.beginConfiguration()
        if captureSession.canAddInput(videoInput) {
            captureSession.addInput(videoInput)
        } else {
            captureSession.commitConfiguration()
            onError?("Unable to attach camera input to capture session.")
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            if metadataOutput.availableMetadataObjectTypes.contains(.qr) {
                metadataOutput.metadataObjectTypes = [.qr]
            }
        } else {
            captureSession.commitConfiguration()
            onError?("Unable to configure QR metadata output.")
            return
        }
        captureSession.commitConfiguration()

        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.frame = view.layer.bounds
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        previewLayer = layer
        isConfigured = true

        startSessionIfNeeded()
    }

    private func startSessionIfNeeded() {
        guard isConfigured else { return }
        let box = sessionBox
        sessionQueue.async {
            if !box.session.isRunning {
                box.session.startRunning()
            }
        }
    }

    private func stopSession() {
        let box = sessionBox
        sessionQueue.async {
            if box.session.isRunning {
                box.session.stopRunning()
            }
        }
    }

    private func handleScannedValue(_ value: String) {
        guard !hasEmittedCode else { return }
        hasEmittedCode = true
        stopSession()
        onCodeScanned?(value)
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = readable.stringValue,
              !value.isEmpty
        else { return }

        Task { @MainActor [weak self] in
            self?.handleScannedValue(value)
        }
    }
}
#else
struct QRScannerView: View {
    let onCodeScanned: (String) -> Void
    var body: some View {
        ContentUnavailableView("QR Scanner Unavailable", systemImage: "qrcode")
    }
}
#endif
