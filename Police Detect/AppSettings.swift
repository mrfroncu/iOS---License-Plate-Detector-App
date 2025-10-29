import Foundation
import SwiftUI
import Combine
import AVFoundation

final class AppSettings: ObservableObject {

    // MARK: - Lens (obiektyw)
    enum LensOption: String, CaseIterable, Identifiable {
        case wide = "Szeroki"
        case ultraWide = "Ultra-szeroki"
        case telephoto = "Tele"
        var id: String { rawValue }

        var deviceType: AVCaptureDevice.DeviceType {
            switch self {
            case .wide:      return .builtInWideAngleCamera
            case .ultraWide: return .builtInUltraWideCamera
            case .telephoto: return .builtInTelephotoCamera
            }
        }
    }
    @Published var selectedLens: LensOption = .wide

    // MARK: - Fokus
    enum FocusMode: String, CaseIterable, Identifiable { case auto = "Auto", manual = "Manual"; var id: String { rawValue } }
    @Published var focusMode: FocusMode = .auto
    @Published var manualLensPosition: Float = 0.5      // 0...1

    // MARK: - Ekspozycja
    enum ExposureMode: String, CaseIterable, Identifiable { case auto = "Auto", manual = "Manual"; var id: String { rawValue } }
    @Published var isoMode: ExposureMode = .auto
    @Published var shutterMode: ExposureMode = .auto
    @Published var manualISO: Float = 200               // 50...maxISO
    @Published var manualShutterSpeed: Double = 1/200   // sekundy (np. 0.005)

    // MARK: - OCR
    enum OCRMode: String, CaseIterable, Identifiable { case simple = "Prosty (wszystko)", plates = "Tablice"; var id: String { rawValue } }
    @Published var ocrMode: OCRMode = .simple

    enum PlateDetectionDetail: String, CaseIterable, Identifiable { case wide = "Szerokie (2.5–7.5)", precise = "Precyzyjne (4.2–4.8)"; var id: String { rawValue } }
    @Published var plateDetail: PlateDetectionDetail = .wide

    // co ile przetwarzamy klatkę
    @Published var detectionInterval: Double = 0.15

    // MARK: - Alerty / głos
    @Published var playSound: Bool = true
    @Published var playHaptic: Bool = true
    @Published var voiceEnabled: Bool = true

    // MARK: - Debug
    @Published var debugMode: Bool = false

    // MARK: - Lista tablic z serwera
    @Published var plateList: [String] = []
    @Published var lastPlateUpdate: Date? = nil

    let platesURL = URL(string: "https://10.10.84.55/ios/tablice.txt")! //change for production server

    func refreshPlateList() {
        DispatchQueue.global(qos: .background).async {
            guard let data = try? Data(contentsOf: self.platesURL),
                  let text = String(data: data, encoding: .utf8) else { return }
            let list = text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
                .filter { !$0.isEmpty }
            DispatchQueue.main.async {
                self.plateList = list
                self.lastPlateUpdate = Date()
            }
        }
    }

    var lastUpdateString: String {
        guard let d = lastPlateUpdate else { return "Nigdy" }
        let f = DateFormatter(); f.dateFormat = "dd.MM.yyyy HH:mm:ss"; return f.string(from: d)
    }

    // Info
    let appVersion = "2.5"
    let appAuthor  = "mrfroncu"
}
