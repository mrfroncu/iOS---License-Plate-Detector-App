import Foundation
import AVFoundation
import UIKit
import Combine

/// Zarządza dwiema sesjami: główną (Scanner) i podglądem (Settings).
final class CameraManager: NSObject, ObservableObject {

    // Ustawienia
    @Published var settings: AppSettings

    // Sesje
    let mainSession = AVCaptureSession()
    let previewSession = AVCaptureSession()

    // Callback z klatkami z GŁÓWNEJ sesji (do OCR w ScannerView)
    var frameHandler: ((CMSampleBuffer, CGImagePropertyOrientation) -> Void)?

    // Urządzenia / wejścia
    private var mainDevice: AVCaptureDevice?
    private var previewDevice: AVCaptureDevice?
    private var mainInput: AVCaptureDeviceInput?
    private var previewInput: AVCaptureDeviceInput?

    // Wyjścia (main ma delegata, preview – tylko warstwa)
    private var mainOutput = AVCaptureVideoDataOutput()
    private var previewOutput = AVCaptureVideoDataOutput()

    private let mainQueue   = DispatchQueue(label: "camera.main.queue")
    private var cancellables = Set<AnyCancellable>()
    private var lastKnownInterfaceOrientation: UIInterfaceOrientation = .portrait

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        bindSettings()
        configureMainSession()
        configurePreviewSession()
    }

    // MARK: Public control

    func startMainSession() {
        stopPreviewSession()
        if !mainSession.isRunning { mainSession.startRunning() }
    }

    func stopMainSession() {
        if mainSession.isRunning { mainSession.stopRunning() }
    }

    func startPreviewSession() {
        stopMainSession()
        if !previewSession.isRunning { previewSession.startRunning() }
    }

    func stopPreviewSession() {
        if previewSession.isRunning { previewSession.stopRunning() }
    }

    // MARK: Settings binding

    private func bindSettings() {
        // zmiana obiektywu
        settings.$selectedLens
            .sink { [weak self] _ in self?.switchLens() }
            .store(in: &cancellables)

        // fokus
        settings.$focusMode
            .sink { [weak self] _ in self?.applyFocus(to: .bothIfRunning) }
            .store(in: &cancellables)
        settings.$manualLensPosition
            .sink { [weak self] _ in self?.applyFocus(to: .bothIfRunning) }
            .store(in: &cancellables)

        // ekspozycja
        settings.$isoMode
            .sink { [weak self] _ in self?.applyExposure(to: .bothIfRunning) }
            .store(in: &cancellables)
        settings.$shutterMode
            .sink { [weak self] _ in self?.applyExposure(to: .bothIfRunning) }
            .store(in: &cancellables)
        settings.$manualISO
            .sink { [weak self] _ in self?.applyExposure(to: .bothIfRunning) }
            .store(in: &cancellables)
        settings.$manualShutterSpeed
            .sink { [weak self] _ in self?.applyExposure(to: .bothIfRunning) }
            .store(in: &cancellables)
    }

    // MARK: Configuration

    private func configureMainSession() {
        mainSession.beginConfiguration()
        mainSession.sessionPreset = .high

        // Input
        if let input = mainInput { mainSession.removeInput(input) }
        mainDevice = pickDevice(of: settings.selectedLens.deviceType)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        if let dev = mainDevice, let inp = try? AVCaptureDeviceInput(device: dev), mainSession.canAddInput(inp) {
            mainSession.addInput(inp); mainInput = inp
        }

        // Output
        if mainSession.outputs.contains(mainOutput) { mainSession.removeOutput(mainOutput) }
        mainOutput = AVCaptureVideoDataOutput()
        mainOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        mainOutput.alwaysDiscardsLateVideoFrames = true
        mainOutput.setSampleBufferDelegate(self, queue: mainQueue)
        if mainSession.canAddOutput(mainOutput) { mainSession.addOutput(mainOutput) }

        setConnectionRotation(for: mainOutput)
        mainSession.commitConfiguration()

        applyFocus(to: .mainOnly)
        applyExposure(to: .mainOnly)
    }

    private func configurePreviewSession() {
        previewSession.beginConfiguration()
        previewSession.sessionPreset = .high

        // Input
        if let input = previewInput { previewSession.removeInput(input) }
        previewDevice = pickDevice(of: settings.selectedLens.deviceType)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        if let dev = previewDevice, let inp = try? AVCaptureDeviceInput(device: dev), previewSession.canAddInput(inp) {
            previewSession.addInput(inp); previewInput = inp
        }

        // Output (bez delegata)
        if previewSession.outputs.contains(previewOutput) { previewSession.removeOutput(previewOutput) }
        previewOutput = AVCaptureVideoDataOutput()
        previewOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if previewSession.canAddOutput(previewOutput) { previewSession.addOutput(previewOutput) }

        setConnectionRotation(for: previewOutput)
        previewSession.commitConfiguration()

        applyFocus(to: .previewOnly)
        applyExposure(to: .previewOnly)
    }

    private func switchLens() {
        // reconfigure obu sesji z nowym deviceType
        reconfigure(session: mainSession, currentInput: &mainInput, device: &mainDevice, deviceType: settings.selectedLens.deviceType)
        reconfigure(session: previewSession, currentInput: &previewInput, device: &previewDevice, deviceType: settings.selectedLens.deviceType)
        applyFocus(to: .bothIfRunning)
        applyExposure(to: .bothIfRunning)
    }

    private func reconfigure(session: AVCaptureSession,
                             currentInput: inout AVCaptureDeviceInput?,
                             device: inout AVCaptureDevice?,
                             deviceType: AVCaptureDevice.DeviceType) {
        session.beginConfiguration()
        if let input = currentInput { session.removeInput(input) }
        device = pickDevice(of: deviceType) ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        if let dev = device, let inp = try? AVCaptureDeviceInput(device: dev), session.canAddInput(inp) {
            session.addInput(inp); currentInput = inp
        }
        // obrót
        if session == mainSession { setConnectionRotation(for: mainOutput) }
        else { setConnectionRotation(for: previewOutput) }
        session.commitConfiguration()
    }

    // MARK: Rotation

    private func setConnectionRotation(for output: AVCaptureVideoDataOutput) {
        guard let conn = output.connection(with: .video) else { return }
        if let o = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first?.interfaceOrientation {
            lastKnownInterfaceOrientation = o
        }
        let angle: CGFloat
        switch lastKnownInterfaceOrientation {
        case .portrait:           angle = 90
        case .portraitUpsideDown: angle = 270
        case .landscapeLeft:      angle = 180
        case .landscapeRight:     angle = 0
        @unknown default:         angle = 90
        }
        if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
    }

    private func currentCGImageOrientation() -> CGImagePropertyOrientation {
        switch lastKnownInterfaceOrientation {
        case .portrait:           return .right
        case .portraitUpsideDown: return .left
        case .landscapeLeft:      return .down
        case .landscapeRight:     return .up
        @unknown default:         return .right
        }
    }

    // MARK: Focus & Exposure

    private enum ApplyTarget { case mainOnly, previewOnly, bothIfRunning }

    private func applyFocus(to target: ApplyTarget) {
        func set(_ device: AVCaptureDevice?) {
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                switch settings.focusMode {
                case .auto:
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    } else if device.isFocusModeSupported(.autoFocus) {
                        device.focusMode = .autoFocus
                    }
                case .manual:
                    if device.isFocusModeSupported(.locked) {
                        device.setFocusModeLocked(lensPosition: max(0, min(1, settings.manualLensPosition)), completionHandler: nil)
                    }
                }
                device.unlockForConfiguration()
            } catch { print("Focus config failed: \(error)") }
        }
        switch target {
        case .mainOnly:    set(mainDevice)
        case .previewOnly: set(previewDevice)
        case .bothIfRunning:
            if mainSession.isRunning { set(mainDevice) }
            if previewSession.isRunning { set(previewDevice) }
        }
    }

    private func applyExposure(to target: ApplyTarget) {
        func set(_ device: AVCaptureDevice?) {
            guard let device else { return }
            do {
                try device.lockForConfiguration()
                let wantsCustom = (settings.isoMode == .manual) || (settings.shutterMode == .manual)
                if wantsCustom, device.isExposureModeSupported(.custom) {
                    let iso = (settings.isoMode == .manual)
                        ? max(device.activeFormat.minISO, min(settings.manualISO, device.activeFormat.maxISO))
                        : device.iso
                    let shutter = (settings.shutterMode == .manual)
                        ? settings.manualShutterSpeed
                        : CMTimeGetSeconds(device.exposureDuration)
                    let dur = CMTimeMakeWithSeconds(shutter, preferredTimescale: 1_000_000_000)
                    device.setExposureModeCustom(duration: dur, iso: iso, completionHandler: nil)
                } else if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.unlockForConfiguration()
            } catch { print("Exposure config failed: \(error)") }
        }
        switch target {
        case .mainOnly:    set(mainDevice)
        case .previewOnly: set(previewDevice)
        case .bothIfRunning:
            if mainSession.isRunning { set(mainDevice) }
            if previewSession.isRunning { set(previewDevice) }
        }
    }

    // MARK: Device discovery

    private func pickDevice(of type: AVCaptureDevice.DeviceType) -> AVCaptureDevice? {
        let ds = AVCaptureDevice.DiscoverySession(deviceTypes: [type], mediaType: .video, position: .back)
        return ds.devices.first
    }
}

// MARK: - Delegate (frames → handler)

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard output == mainOutput else { return } // preview nie ma handlera
        frameHandler?(sampleBuffer, currentCGImageOrientation())
    }
}
