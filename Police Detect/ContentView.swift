import SwiftUI
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins
import AudioToolbox
import MessageUI
import AVKit
import UIKit

// MARK: - App entry

@main
struct Police_detectApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var cameraManager: CameraManager
    @StateObject private var store = PlateStore()

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _cameraManager = StateObject(wrappedValue: CameraManager(settings: s))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(cameraManager)
                .environmentObject(store)
        }
    }
}

// MARK: - Models / Store

struct RecognizedItem: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let bbox: CGRect          // Vision 0..1
    let isMatch: Bool
    let date: Date
}

struct DebugCrop: Identifiable {
    let id = UUID()
    let image: UIImage
    let timestamp: Date
    let recognized: String?
}

final class PlateStore: ObservableObject {
    @Published var recognized: [RecognizedItem] = []
    @Published var showMatchOverlay = false
    @Published var debugCrops: [DebugCrop] = [] // ostatnie przycinki dla OCR (do DebugView)

    private var lastAlert = Date.distantPast
    private let synth = AVSpeechSynthesizer()

    func add(_ item: RecognizedItem, settings: AppSettings) {
        recognized.insert(item, at: 0)
        if item.isMatch { alert(settings: settings); speak(plate: item.text, settings: settings) }
    }

    func addCrop(_ image: UIImage, recognized: String?) {
        debugCrops.insert(DebugCrop(image: image, timestamp: Date(), recognized: recognized), at: 0)
        if debugCrops.count > 20 { debugCrops.removeLast(debugCrops.count - 20) }
    }

    private func alert(settings: AppSettings) {
        let now = Date()
        guard now.timeIntervalSince(lastAlert) > 1.2 else { return }
        lastAlert = now
        if settings.playHaptic { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        if settings.playSound { AudioServicesPlaySystemSound(1005) }
        withAnimation(.easeInOut(duration: 0.12)) { showMatchOverlay = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.showMatchOverlay = false }
    }

    private func speak(plate: String, settings: AppSettings) {
        guard settings.voiceEnabled else { return }
        let v = AVSpeechSynthesisVoice(language: "pl-PL")
        let u1 = AVSpeechUtterance(string: "Uwaga, nieoznakowany radiowóz.")
        u1.voice = v; u1.rate = 0.46
        let u2 = AVSpeechUtterance(string: plate); u2.voice = v; u2.rate = 0.5
        synth.stopSpeaking(at: .immediate); synth.speak(u1)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.synth.speak(u2) }
    }
}

// MARK: - Root tabs (Debug trafi do „More” jako 7. karta)

struct RootView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var store: PlateStore

    var body: some View {
        TabView {
            ScannerView()
                .tabItem { Label("Scanner", systemImage: "camera.viewfinder") }

            AllDetectionsView()
                .tabItem { Label("Detekcje", systemImage: "text.viewfinder") }

            MatchesView()
                .tabItem { Label("Matches", systemImage: "list.bullet.rectangle") }

            AnalyzeFileView()
                .tabItem { Label("Analiza", systemImage: "film") }

            ReportView()
                .tabItem { Label("Zgłoś", systemImage: "envelope.badge") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }

            DebugView()
                .tabItem { Label("Debug", systemImage: "ladybug") }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            settings.refreshPlateList()
            cameraManager.startMainSession()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            cameraManager.stopMainSession()
        }
    }
}

// MARK: - Scanner view (fullscreen, overlay 30%, poprawiony OCR)

struct ScannerView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var cameraManager: CameraManager
    @EnvironmentObject var store: PlateStore

    @State private var lastProcess = Date.distantPast
    @State private var frameAspect: CGFloat = 16/9

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreviewView(session: cameraManager.mainSession)
                .ignoresSafeArea()
                .onAppear { hookFrames() }

            if settings.debugMode {
                BoundingBoxesOverlay(items: Array(store.recognized.prefix(25)), videoAspect: frameAspect)
                    .allowsHitTesting(false)
            }

            overlayPanel()
                .padding(.horizontal, 10).padding(.bottom, 10)

            if store.showMatchOverlay {
                Rectangle().fill(Color.red.opacity(0.92)).frame(height: 70)
                    .overlay(Text("MATCH!").bold().foregroundColor(.white))
                    .transition(.opacity)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }

    private func hookFrames() {
        cameraManager.frameHandler = { sample, orientation in
            let now = Date()
            if now.timeIntervalSince(lastProcess) < max(0.05, settings.detectionInterval) { return }
            lastProcess = now

            guard let buf = CMSampleBufferGetImageBuffer(sample) else { return }
            frameAspect = CGFloat(CVPixelBufferGetWidth(buf)) / CGFloat(CVPixelBufferGetHeight(buf))

            switch settings.ocrMode {
            case .simple: runSimpleOCR(buffer: buf, orientation: orientation)
            case .plates: runPlateOCR(buffer: buf, orientation: orientation)
            }
        }
    }

    // MARK: OCR simple – pełna klatka, z filtrem regex

    private func runSimpleOCR(buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let req = VNRecognizeTextRequest { [settings, store] r, _ in
            guard let arr = r.results as? [VNRecognizedTextObservation] else { return }
            for o in arr {
                guard let s = o.topCandidates(1).first?.string else { continue }
                let txt = normalize(s)
                guard !txt.isEmpty else { continue }
                let looksLikePlate = self.looksLikePotentialPlate(txt)
                let isMatch = looksLikePlate && settings.plateList.contains(txt)
                let it = RecognizedItem(text: txt, bbox: o.boundingBox, isMatch: isMatch, date: Date())
                DispatchQueue.main.async { store.add(it, settings: settings) }
                if isMatch { break }
            }
        }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = false
        req.minimumTextHeight = 0.02
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:]).perform([req])
    }

    // MARK: OCR plates – prostokąty + jasne tło + regex

    private func runPlateOCR(buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation) {
        let rect = VNDetectRectanglesRequest()
        rect.minimumSize = 0.03
        rect.maximumObservations = 12
        rect.minimumAspectRatio = 0.2

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation, options: [:])
        try? handler.perform([rect])

        guard let rects = rect.results as? [VNRectangleObservation], !rects.isEmpty else {
            return // w trybie plates nie robimy fallbacku – chcemy widzieć w DebugView co się dzieje
        }

        let ci = CIImage(cvPixelBuffer: buffer)
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)

        let filtered = rects.filter { o in
            let r = o.boundingBox
            let ar = r.width / r.height
            let aspectOK: Bool = (settings.plateDetail == .wide) ? (ar > 2.5 && ar < 7.5) : (ar > 4.2 && ar < 4.8)
            return aspectOK && r.minY < 0.95
        }.prefix(12)

        guard !filtered.isEmpty else { return }

        for obs in filtered {
            var r = obs.boundingBox
            // padding wokół, by złapać całe pole tablicy
            r = r.insetBy(dx: -0.08*r.width, dy: -0.18*r.height)
            r.origin.x = max(0, r.origin.x); r.origin.y = max(0, r.origin.y)
            r.size.width = min(1 - r.origin.x, r.size.width)
            r.size.height = min(1 - r.origin.y, r.size.height)

            let cropRect = CGRect(x: r.minX * CGFloat(bw),
                                  y: r.minY * CGFloat(bh),
                                  width: r.width * CGFloat(bw),
                                  height: r.height * CGFloat(bh))
            let sub = ci.cropped(to: cropRect)

            // heurystyka jasnego tła
            guard isBrightBackground(ciImage: sub) else {
                // pokaż w debug też te odrzucone (bez tekstu)
                if let cg = CIContext().createCGImage(sub, from: sub.extent) {
                    DispatchQueue.main.async { store.addCrop(UIImage(cgImage: cg), recognized: nil) }
                }
                continue
            }

            guard let cg = CIContext().createCGImage(sub, from: sub.extent) else { continue }

            let req = VNRecognizeTextRequest { [settings, store] r, _ in
                guard let arr = r.results as? [VNRecognizedTextObservation] else {
                    DispatchQueue.main.async { store.addCrop(UIImage(cgImage: cg), recognized: nil) }
                    return
                }
                var bestFound: String? = nil
                for o in arr {
                    guard let s = o.topCandidates(1).first?.string else { continue }
                    let txt = self.normalize(s)
                    guard self.looksLikePotentialPlate(txt) else { continue }
                    bestFound = txt
                    let isMatch = settings.plateList.contains(txt)
                    let it = RecognizedItem(text: txt, bbox: obs.boundingBox, isMatch: isMatch, date: Date())
                    DispatchQueue.main.async { store.add(it, settings: settings) }
                    if isMatch { break }
                }
                DispatchQueue.main.async { store.addCrop(UIImage(cgImage: cg), recognized: bestFound) }
            }
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            req.minimumTextHeight = 0.02

            try? VNImageRequestHandler(cgImage: cg, orientation: orientation, options: [:]).perform([req])
        }
    }

    // MARK: Helpers

    private let ciContext = CIContext()

    private func isBrightBackground(ciImage: CIImage) -> Bool {
        let f = CIFilter.areaAverage(); f.inputImage = ciImage; f.extent = ciImage.extent
        guard let out = f.outputImage else { return false }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let y = 0.2126*Float(px[0])/255 + 0.7152*Float(px[1])/255 + 0.0722*Float(px[2])/255
        return y > 0.60
    }

    private func looksLikePotentialPlate(_ txt: String) -> Bool {
        // 4–8 znaków, minimum 1 cyfra
        guard (4...8).contains(txt.count) else { return false }
        let hasDigit = txt.rangeOfCharacter(from: .decimalDigits) != nil
        let allAN = txt.rangeOfCharacter(from: CharacterSet.alphanumerics.inverted) == nil
        return hasDigit && allAN
    }

    private func normalize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return s.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined().uppercased()
    }

    @ViewBuilder
    private func overlayPanel() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Image(systemName: "text.viewfinder"); Text("Ostatnie rozpoznania"); Spacer() }.font(.headline)
            ForEach(store.recognized.prefix(5)) { it in
                HStack {
                    Text(it.text).font(.system(.body, design: .monospaced))
                    Spacer()
                    if it.isMatch { Image(systemName: "checkmark.seal.fill").foregroundColor(.red) }
                }.padding(.vertical, 4)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Bounding boxes overlay

struct BoundingBoxesOverlay: View {
    let items: [RecognizedItem]
    let videoAspect: CGFloat

    var body: some View {
        GeometryReader { g in
            let layer = g.size
            ForEach(items) { it in
                let r = mapRect(layer: layer, contentAspect: videoAspect, norm: it.bbox)
                Rectangle()
                    .stroke(it.isMatch ? Color.red : Color.green, lineWidth: it.isMatch ? 3 : 2)
                    .frame(width: r.width, height: r.height)
                    .position(x: r.midX, y: r.midY)
            }
        }
        .ignoresSafeArea()
    }

    private func mapRect(layer: CGSize, contentAspect: CGFloat, norm: CGRect) -> CGRect {
        let layerAspect = layer.width / layer.height
        let contentRect: CGRect
        if layerAspect > contentAspect {
            let w = layer.height * contentAspect
            contentRect = CGRect(x: (layer.width - w)/2, y: 0, width: w, height: layer.height)
        } else {
            let h = layer.width / contentAspect
            contentRect = CGRect(x: 0, y: (layer.height - h)/2, width: layer.width, height: h)
        }
        let x = contentRect.minX + norm.minX * contentRect.width
        let w = norm.width * contentRect.width
        let h = norm.height * contentRect.height
        let yFromBottom = norm.minY * contentRect.height
        let y = contentRect.maxY - yFromBottom - h
        return CGRect(x: x, y: y, width: w, height: h)
    }
}

// MARK: - Detekcje

struct AllDetectionsView: View {
    @EnvironmentObject var store: PlateStore
    @State private var q = ""
    var filtered: [RecognizedItem] {
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return s.isEmpty ? store.recognized : store.recognized.filter { $0.text.contains(s) }
    }
    var body: some View {
        NavigationView {
            List(filtered) { it in
                HStack {
                    VStack(alignment: .leading) {
                        Text(it.text).font(.system(.body, design: .monospaced))
                        Text(Self.df.string(from: it.date)).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    if it.isMatch { Image(systemName: "checkmark.seal.fill").foregroundColor(.red) }
                }.padding(.vertical, 4)
            }
            .searchable(text: $q, prompt: "Szukaj…")
            .navigationTitle("Detekcje")
        }
    }
    static let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .short; d.timeStyle = .medium; return d }()
}

// MARK: - Matches

struct MatchesView: View {
    @EnvironmentObject var store: PlateStore
    @State private var draft: MailDraft?
    var matches: [RecognizedItem] { store.recognized.filter { $0.isMatch } }
    var body: some View {
        NavigationView {
            List(matches) { it in
                HStack {
                    VStack(alignment: .leading) {
                        Text(it.text).bold()
                        Text(Self.df.string(from: it.date)).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Zgłoś błąd") {
                        draft = MailDraft(
                            subject: "Zgłoszenie błędu - \(it.text)",
                            body:
"""
Zgłaszam błąd w wykryciu tablicy rejestracyjnej:
\(it.text)

Data: \(Self.df.string(from: it.date))

Powód:
(wpisz opis)
"""
                        )
                    }
                    .buttonStyle(.borderedProminent).tint(.red)
                }.padding(.vertical, 6)
            }
            .navigationTitle("Matches")
            .sheet(item: $draft) { d in
                MailView(subject: d.subject, body: d.body, toRecipients: ["mrfroncu+aplikacjatablice@gmail.com"])
            }
        }
    }
    static let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .short; d.timeStyle = .medium; return d }()
}
struct MailDraft: Identifiable { let id = UUID(); let subject: String; let body: String }

// MARK: - Analyze file

struct AnalyzeFileView: View {
    @State private var pickedImage: UIImage?
    @State private var pickedVideoURL: URL?
    @State private var results: [RecognizedItem] = []
    @State private var q = ""
    @State private var processingVideo = false

    var filtered: [RecognizedItem] {
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return s.isEmpty ? results : results.filter { $0.text.contains(s) }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                HStack {
                    Button { pickedImage = nil; pickedVideoURL = nil; results.removeAll(); showImagePicker = true } label: { ButtonLabel(title: "Zdjęcie", system: "photo") }
                    Button { pickedImage = nil; pickedVideoURL = nil; results.removeAll(); showVideoPicker = true } label: { ButtonLabel(title: "Wideo", system: "film") }
                }

                if let img = pickedImage {
                    Image(uiImage: img).resizable().scaledToFit().frame(maxHeight: 240).cornerRadius(12).padding(.horizontal, 12)
                    Button { results.removeAll(); runImageOCR(image: img) } label: { ButtonLabel(title: "Rozpoznaj zdjęcie", system: "text.viewfinder") }
                }

                if let url = pickedVideoURL {
                    VideoPlayer(player: AVPlayer(url: url)).frame(height: 220).cornerRadius(12).padding(.horizontal, 12)
                    HStack {
                        Button { results.removeAll(); processingVideo = true; runVideoOCR(url: url) { processingVideo = false } } label: { ButtonLabel(title: "Start OCR", system: "play.circle") }.disabled(processingVideo)
                        Button { processingVideo = false } label: { ButtonLabel(title: "Stop", system: "stop.circle") }.disabled(!processingVideo)
                    }
                }

                List(filtered) { it in
                    HStack {
                        Text(it.text).font(.system(.body, design: .monospaced))
                        Spacer()
                        Text(Self.df.string(from: it.date)).font(.caption).foregroundColor(.secondary)
                    }.padding(.vertical, 4)
                }
                .searchable(text: $q, prompt: "Szukaj…")
            }
            .padding(.vertical, 8)
            .navigationTitle("Analiza pliku")
        }
        .sheet(isPresented: $showImagePicker) { ImagePicker(image: $pickedImage) }
        .sheet(isPresented: $showVideoPicker) { VideoPicker(videoURL: $pickedVideoURL) }
    }

    // Picker state
    @State private var showImagePicker = false
    @State private var showVideoPicker = false

    private func runImageOCR(image: UIImage) {
        guard let cg = image.cgImage else { return }
        let req = VNRecognizeTextRequest { r, _ in
            if let arr = r.results as? [VNRecognizedTextObservation] {
                for o in arr {
                    if let s = o.topCandidates(1).first?.string {
                        let t = normalize(s); guard !t.isEmpty else { continue }
                        results.insert(RecognizedItem(text: t, bbox: o.boundingBox, isMatch: false, date: Date()), at: 0)
                    }
                }
            }
        }
        req.recognitionLevel = .accurate; req.usesLanguageCorrection = false; req.minimumTextHeight = 0.02
        try? VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([req])
    }

    private func runVideoOCR(url: URL, completion: @escaping () -> Void) {
        let asset = AVAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset); gen.appliesPreferredTrackTransform = true
        let duration = CMTimeGetSeconds(asset.duration)
        var times: [NSValue] = []; var t = 0.0; let step = 0.15
        while t <= duration { times.append(NSValue(time: CMTimeMakeWithSeconds(t, preferredTimescale: 600))); t += step }

        let group = DispatchGroup()
        for time in times {
            group.enter()
            gen.generateCGImagesAsynchronously(forTimes: [time]) { _, cg, _, _, _ in
                if let cg = cg {
                    let req = VNRecognizeTextRequest { r, _ in
                        if let arr = r.results as? [VNRecognizedTextObservation] {
                            for o in arr {
                                if let s = o.topCandidates(1).first?.string {
                                    let t = self.normalize(s); guard !t.isEmpty else { continue }
                                    DispatchQueue.main.async {
                                        self.results.insert(RecognizedItem(text: t, bbox: o.boundingBox, isMatch: false, date: Date()), at: 0)
                                    }
                                }
                            }
                        }
                    }
                    req.recognitionLevel = .accurate; req.usesLanguageCorrection = false; req.minimumTextHeight = 0.02
                    try? VNImageRequestHandler(cgImage: cg, orientation: .up, options: [:]).perform([req])
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion() }
    }

    private func normalize(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        return s.unicodeScalars.filter { allowed.contains($0) }.map(String.init).joined().uppercased()
    }

    static let df: DateFormatter = { let d = DateFormatter(); d.dateStyle = .short; d.timeStyle = .medium; return d }()
}

// MARK: - Settings (podgląd z osobnej sesji, wybór obiektywu)

struct SettingsView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var cameraManager: CameraManager

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Podgląd (Settings)")) {
                    CameraPreviewView(session: cameraManager.previewSession)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16/9, contentMode: .fit)
                        .cornerRadius(10)
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2)))
                }

                Section(header: Text("Obiektyw")) {
                    Picker("Wybierz", selection: $settings.selectedLens) {
                        ForEach(AppSettings.LensOption.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }

                Section(header: Text("OCR")) {
                    HStack {
                        Text("Interwał"); Slider(value: $settings.detectionInterval, in: 0.05...1.0, step: 0.05)
                        Text("\(settings.detectionInterval, specifier: "%.2f")s").monospacedDigit().frame(width: 60)
                    }
                    Picker("Tryb", selection: $settings.ocrMode) {
                        ForEach(AppSettings.OCRMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if settings.ocrMode == .plates {
                        Picker("Detekcja tablic", selection: $settings.plateDetail) {
                            ForEach(AppSettings.PlateDetectionDetail.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                }

                Section(header: Text("Fokus")) {
                    Picker("Tryb ostrości", selection: $settings.focusMode) {
                        ForEach(AppSettings.FocusMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)

                    if settings.focusMode == .manual {
                        HStack {
                            Text("Lens")
                            Slider(value: Binding(get: { Double(settings.manualLensPosition) },
                                                  set: { settings.manualLensPosition = Float($0) }),
                                   in: 0...1, step: 0.01)
                            Text("\(settings.manualLensPosition, specifier: "%.2f")").monospacedDigit().frame(width: 60)
                        }
                    }
                }

                Section(header: Text("Ekspozycja")) {
                    HStack { Text("ISO"); Spacer()
                        Picker("", selection: $settings.isoMode) { ForEach(AppSettings.ExposureMode.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).frame(width: 160)
                    }
                    if settings.isoMode == .manual {
                        HStack { Slider(value: $settings.manualISO, in: 50...1000, step: 10)
                            Text("\(Int(settings.manualISO))").monospacedDigit().frame(width: 60) }
                    }
                    Divider()
                    HStack { Text("Shutter"); Spacer()
                        Picker("", selection: $settings.shutterMode) { ForEach(AppSettings.ExposureMode.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.segmented).frame(width: 160)
                    }
                    if settings.shutterMode == .manual {
                        HStack {
                            Slider(value: $settings.manualShutterSpeed, in: (1/2000)...(1/10), step: 1/1000)
                            Text("1/\(Int(1/settings.manualShutterSpeed))s").monospacedDigit().frame(width: 90, alignment: .trailing)
                        }
                    }
                }

                Section(header: Text("Lista tablic")) {
                    Button { settings.refreshPlateList() } label: { Label("Odśwież listę", systemImage: "arrow.clockwise.circle.fill") }
                    Text("Ostatnie pobranie: \(settings.lastUpdateString)").font(.caption).foregroundColor(.secondary)
                    if !settings.plateList.isEmpty {
                        Text("Łącznie: \(settings.plateList.count)").font(.caption).foregroundColor(.secondary)
                    }
                }

                Section(header: Text("Debug / Info")) {
                    Toggle("Bounding boxes", isOn: $settings.debugMode)
                    Toggle("Dźwięk", isOn: $settings.playSound)
                    Toggle("Haptyka", isOn: $settings.playHaptic)
                    Toggle("Głos PL", isOn: $settings.voiceEnabled)
                    HStack { Text("Wersja"); Spacer(); Text(settings.appVersion).foregroundColor(.secondary) }
                    HStack { Text("Autor");  Spacer(); Text(settings.appAuthor).foregroundColor(.secondary) }
                }
            }
            .navigationTitle("Settings")
            .onAppear { cameraManager.startPreviewSession() }
            .onDisappear { cameraManager.stopPreviewSession(); cameraManager.startMainSession() }
        }
    }
}

// MARK: - Debug (miniatury cropów + timestamp)

struct DebugView: View {
    @EnvironmentObject var store: PlateStore

    static let df: DateFormatter = {
        let d = DateFormatter()
        d.dateStyle = .none
        d.timeStyle = .medium
        return d
    }()

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 12)], spacing: 12) {
                    ForEach(store.debugCrops) { crop in
                        VStack(alignment: .leading, spacing: 6) {
                            Image(uiImage: crop.image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 120, height: 72)
                                .clipped()
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(crop.recognized == nil ? Color.orange.opacity(0.6) : Color.green.opacity(0.8), lineWidth: 2)
                                )
                            Text(crop.recognized ?? "— brak —")
                                .font(.caption)
                                .lineLimit(1)
                            Text(Self.df.string(from: crop.timestamp))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(12)
            }
            .navigationTitle("Debug OCR")
        }
    }
}

// MARK: - UI helpers

struct ButtonLabel: View {
    let title: String; let system: String
    var body: some View {
        Label(title, systemImage: system)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ImagePicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    @Binding var image: UIImage?
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController(); p.delegate = context.coordinator; p.sourceType = .photoLibrary; p.mediaTypes = ["public.image"]; return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: ImagePicker; init(_ parent: ImagePicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage { parent.image = img }; parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct VideoPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss
    @Binding var videoURL: URL?
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController(); p.delegate = context.coordinator; p.sourceType = .photoLibrary; p.mediaTypes = ["public.movie"]; return p
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: VideoPicker; init(_ parent: VideoPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let url = info[.mediaURL] as? URL { parent.videoURL = url }; parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

struct MailView: UIViewControllerRepresentable {
    var subject: String; var body: String; var toRecipients: [String]
    @Environment(\.presentationMode) var presentation
    func makeUIViewController(context: Context) -> MFMailComposeViewController {
        let vc = MFMailComposeViewController()
        vc.mailComposeDelegate = context.coordinator
        vc.setSubject(subject); vc.setMessageBody(body, isHTML: false); vc.setToRecipients(toRecipients)
        return vc
    }
    func updateUIViewController(_ uiViewController: MFMailComposeViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    class Coordinator: NSObject, MFMailComposeViewControllerDelegate {
        var parent: MailView; init(_ parent: MailView) { self.parent = parent }
        func mailComposeController(_ controller: MFMailComposeViewController, didFinishWith result: MFMailComposeResult, error: Error?) {
            parent.presentation.wrappedValue.dismiss()
        }
    }
}
// MARK: - Report (formularz zgłoszenia)

struct ReportView: View {
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Zgłoszenie błędu lub propozycji")) {
                    Text("Tu w przyszłości pojawi się formularz zgłoszeniowy. 😊")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                }

                Section {
                    Link("Wyślij maila do autora", destination: URL(string: "mailto:mrfroncu+aplikacjatablice@gmail.com")!)
                }
            }
            .navigationTitle("Zgłoś problem")
        }
    }
}
