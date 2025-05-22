//
//  ContentView.swift
//  NekoPress
//
//  Created by 千葉牧人 on 2025/5/21.
//

import SwiftUI
import SDWebImage
import SDWebImageWebPCoder
import CoreImage
import ImageIO

let SDImageWebPCoderOptionEncodeMethod = SDImageCoderOption(rawValue: "com.sdwebimage.webp.encodeMethod")
let SDImageWebPCoderOptionThreadLevel = SDImageCoderOption(rawValue: "com.sdwebimage.webp.threadLevel")

struct CompressImage {
    let url: URL
    var image: NSImage? = nil
    var compressedSize: Int? = nil
}

// 新增：用於批次更新 UI 的結構
struct CompressionUpdate {
    let index: Int
    let compressedSize: Int
    let totalSize: Int
}

// 共用全域 CIContext，避免每次呼叫時重新初始化
let sharedCIContext = CIContext()

struct ContentView: View {
    @State private var isDarkMode: Bool = false
    @State private var compressionLevel: String = "中"
    @State private var outputFormat: String = "JPEG"
    @State private var outputFolderURL: URL? = nil
    @State private var progress: Double = 0.0
    @State private var isCompressing: Bool = false
    @State private var images: [CompressImage] = []
    @State private var originalTotalSize: Int = 0
    @State private var compressedTotalSize: Int = 0
    @State private var cancelRequested: Bool = false
    @State private var shouldBackupOriginals: Bool = false
    @State private var showErrorAlert: Bool = false
    @State private var errorMessage: String = ""
    @State private var updateTimer: Timer? = nil
    private let updateQueue = DispatchQueue(label: "com.nekopress.update", attributes: .concurrent)
    private let updateLock = NSLock()
    @State private var pendingUpdates: [CompressionUpdate] = []
    @State private var showAbout: Bool = false

    let compressionLevels = ["快", "中", "慢"]
    let outputFormats = ["JPEG", "WebP"]

    var body: some View {
        VStack(spacing: 16) {
            Toggle(LocalizedStringKey("toggle_dark_mode"), isOn: $isDarkMode)
                .padding(.horizontal)
                .onChange(of: isDarkMode) { _ in
                    saveSettings()
                }

            DropAreaView(images: $images)

            VStack(spacing: 4) {
                Text(LocalizedStringKey("hint_compression_quality"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                Picker(LocalizedStringKey("label_compression_level"), selection: $compressionLevel) {
                    ForEach(compressionLevels, id: \.self) { level in
                        Text(level)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: compressionLevel) { _ in
                    saveSettings()
                }

                Picker(LocalizedStringKey("label_output_format"), selection: $outputFormat) {
                    ForEach(outputFormats, id: \.self) { format in
                        Text(format)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: outputFormat) { _ in
                    saveSettings()
                }
            }

            Button(LocalizedStringKey("button_choose_output_folder")) {
                selectOutputFolder()
            }
            .padding(.top, 8)

            Toggle(LocalizedStringKey("toggle_backup_original"), isOn: $shouldBackupOriginals)
                .padding(.horizontal)

            ProgressView(value: progress)
                .padding(.horizontal)

            if originalTotalSize > 0 {
                let saved = originalTotalSize - compressedTotalSize
                let percent = Double(saved) / Double(originalTotalSize) * 100
                Text(String(format: NSLocalizedString("text_saved_summary", comment: ""), Double(saved) / 1024.0, percent))
                    .font(.subheadline)
                    .foregroundColor(.green)
            }

            HStack {
                Button(LocalizedStringKey("button_start_compression")) {
                    startCompression()
                }
                .disabled(images.isEmpty || isCompressing)

                Button(LocalizedStringKey("button_cancel_compression")) {
                    cancelCompression()
                }
                .disabled(!isCompressing)
            }
            .padding(.horizontal)

            Button(LocalizedStringKey("button_clear_all")) {
                images.removeAll()
            }
            .padding(.bottom, 8)

            // 新增：關於 NekoPress 按鈕
            Button(LocalizedStringKey("about_button")) {
                showAbout = true
            }
        }
        .padding()
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear {
            loadSettings()
        }
        .alert(LocalizedStringKey("alert_compression_failed"), isPresented: $showErrorAlert, actions: {
            Button(LocalizedStringKey("button_ok"), role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
        // 新增：關於 NekoPress sheet
        .sheet(isPresented: $showAbout) {
            VStack(spacing: 16) {
                Text(LocalizedStringKey("about_title"))
                    .font(.title2)
                    .padding(.top, 24)
                Text(LocalizedStringKey("about_version")) // e.g. "版本 1.0"
                    .font(.subheadline)
                Text(LocalizedStringKey("about_languages")) // e.g. "支援語言：繁體中文、English、日本語"
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
                Button(LocalizedStringKey("about_close")) {
                    showAbout = false
                }
                .keyboardShortcut(.cancelAction)
                .padding(.bottom, 24)
            }
            .frame(width: 320, height: 240)
        }
    }

    // 使用 CGImage 並直接產生縮圖 CGImage
    func downscaleCGImage(_ input: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(input.width)
        let height = CGFloat(input.height)
        let ratio = min(maxDimension / width, maxDimension / height, 1.0)

        let transform = CGAffineTransform(scaleX: ratio, y: ratio)
        let ciImage = CIImage(cgImage: input).transformed(by: transform)
        let rect = CGRect(origin: .zero, size: CGSize(width: width * ratio, height: height * ratio))

        return sharedCIContext.createCGImage(ciImage, from: rect)
    }

    func selectOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "選擇"

        if panel.runModal() == .OK {
            outputFolderURL = panel.url
        }
    }

    func startCompression() {
        DispatchQueue.once(token: "com.nekopress.webp") {
            SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
        }

        guard !images.isEmpty else { return }
        cancelRequested = false
        isCompressing = true
        progress = 0.0
        pendingUpdates.removeAll()

        // 計算原始總大小
        originalTotalSize = images.reduce(0) { total, item in
            if let resourceValues = try? item.url.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                return total + fileSize
            }
            return total
        }
        compressedTotalSize = 0

        // 使用 OperationQueue 來更好地控制並行處理
        let operationQueue = OperationQueue()
        // 限制並行數量為 CPU 核心數的一半
        operationQueue.maxConcurrentOperationCount = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
        operationQueue.qualityOfService = .userInitiated

        var processedCount = 0
        let progressLock = NSLock()

        // 啟動 UI 更新計時器
        startUpdateTimer()

        for (index, item) in images.enumerated() {
            if cancelRequested { break }

            let operation = BlockOperation { [self] in
                autoreleasepool {
                    let baseDirectory: URL
                    if let customOutput = outputFolderURL {
                        baseDirectory = customOutput
                    } else {
                        baseDirectory = item.url.deletingLastPathComponent()
                    }

                    let ext = outputFormat.lowercased()
                    let baseName: String
                    if FileManager.default.fileExists(atPath: item.url.path) {
                        baseName = item.url.deletingPathExtension().lastPathComponent
                    } else {
                        baseName = "image_\(index)"
                    }
                    let filename = "\(baseName)_compressed.\(ext)"
                    let fileURL = baseDirectory.appendingPathComponent(filename)

                    guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                        DispatchQueue.main.async {
                            self.errorMessage = String(format: NSLocalizedString("error_cannot_load_image", comment: ""), item.url.lastPathComponent)
                            self.showErrorAlert = true
                        }
                        return
                    }

                    var imageData: Data?
                    switch outputFormat {
                    case "JPEG":
                        let quality: CGFloat
                        switch compressionLevel {
                        case "快": quality = 0.1
                        case "中": quality = 0.3
                        case "慢": quality = 0.5
                        default: quality = 0.3
                        }
                        let bitmap = NSBitmapImageRep(cgImage: cgImage)
                        imageData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
                    case "WebP":
                        let quality: CGFloat
                        switch compressionLevel {
                        case "快": quality = 0.2
                        case "中": quality = 0.5
                        case "慢": quality = 0.8
                        default: quality = 0.5
                        }
                        let resized = self.downscaleCGImage(cgImage, maxDimension: 2048) ?? cgImage
                        let nsImage = NSImage(cgImage: resized, size: NSSize(width: resized.width, height: resized.height))
                        imageData = SDImageWebPCoder.shared.encodedData(
                            with: nsImage,
                            format: .webP,
                            options: [
                                SDImageCoderOption.encodeCompressionQuality: quality,
                                SDImageWebPCoderOptionEncodeMethod: 1,
                                SDImageWebPCoderOptionThreadLevel: true
                            ]
                        )
                    default:
                        break
                    }

                    if let data = imageData {
                        // 使用背景隊列處理檔案寫入
                        DispatchQueue.global(qos: .utility).async { [self] in
                            do {
                                try data.write(to: fileURL)
                                
                                // 更新進度
                                progressLock.lock()
                                processedCount += 1
                                progressLock.unlock()

                                // 將更新加入隊列
                                self.updateQueue.async { [self] in
                                    self.updateLock.lock()
                                    self.pendingUpdates.append(CompressionUpdate(
                                        index: index,
                                        compressedSize: data.count,
                                        totalSize: data.count
                                    ))
                                    self.updateLock.unlock()
                                }

                                // 備份原圖
                                if self.shouldBackupOriginals {
                                    let originFolder = item.url.deletingLastPathComponent().appendingPathComponent("Origin", isDirectory: true)
                                    try? FileManager.default.createDirectory(at: originFolder, withIntermediateDirectories: true)
                                    let backupURL = originFolder.appendingPathComponent(item.url.lastPathComponent)
                                    try? FileManager.default.moveItem(at: item.url, to: backupURL)
                                }
                            } catch {
                                DispatchQueue.main.async {
                                    self.errorMessage = String(format: NSLocalizedString("error_cannot_write_file", comment: ""), fileURL.lastPathComponent)
                                    self.showErrorAlert = true
                                }
                            }
                        }
                    }
                }
            }
            operationQueue.addOperation(operation)
        }

        // 監控完成狀態
        operationQueue.addBarrierBlock {
            DispatchQueue.main.async { [self] in
                self.stopUpdateTimer()
                self.isCompressing = false
            }
        }
    }

    private func startUpdateTimer() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            self.updateUI()
        }
        updateTimer = timer
    }

    private func stopUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = nil
        // 最後一次更新 UI
        updateUI()
    }

    private func updateUI() {
        updateLock.lock()
        let updates = pendingUpdates
        pendingUpdates.removeAll()
        updateLock.unlock()

        guard !updates.isEmpty else { return }

        DispatchQueue.main.async { [self] in
            for update in updates {
                self.compressedTotalSize += update.totalSize
                self.images[update.index].compressedSize = update.compressedSize
            }
            self.progress = Double(updates.count) / Double(self.images.count)
        }
    }

    func cancelCompression() {
        cancelRequested = true
        isCompressing = false
        stopUpdateTimer()
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(compressionLevel, forKey: "compressionLevel")
        defaults.set(outputFormat, forKey: "outputFormat")
        defaults.set(isDarkMode, forKey: "isDarkMode")
    }

    func loadSettings() {
        let defaults = UserDefaults.standard
        if let savedLevel = defaults.string(forKey: "compressionLevel") {
            compressionLevel = savedLevel
        }
        if let savedFormat = defaults.string(forKey: "outputFormat") {
            outputFormat = savedFormat
        }
        isDarkMode = defaults.bool(forKey: "isDarkMode")
    }
}

#Preview {
    ContentView()
}

struct DropAreaView: View {
    @Binding var images: [CompressImage]

    var body: some View {
        VStack {
            if images.isEmpty {
                Rectangle()
                    .fill(Color.clear)
                    .overlay(
                        Text(LocalizedStringKey("drop_hint"))
                            .foregroundColor(.secondary)
                    )
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, item in
                            VStack {
                                imagePreview(for: index, item: item)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .frame(height: 180)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(12)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { item, error in
                    guard let url = item, error == nil else { return }

                    let allowedExtensions = ["jpg", "jpeg", "png", "bmp", "heic", "heif"]
                    guard allowedExtensions.contains(url.pathExtension.lowercased()) else { return }

                    DispatchQueue.main.async {
                        let imageItem = CompressImage(url: url)
                        images.append(imageItem)
                    }
                }
            }
            return true
        }
    }

    func imagePreview(for index: Int, item: CompressImage) -> some View {
        let nsImage = NSImage(contentsOf: item.url) ?? NSImage(size: .zero)
        // 不再修改 state during view rendering

        let size = nsImage.size
        let fileSizeText: String = {
            if let resourceValues = try? item.url.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                return String(format: "%.1f KB", Double(fileSize) / 1024.0)
            }
            return ""
        }()

        return VStack {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 100, height: 100)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.gray.opacity(0.5)))

            VStack(spacing: 2) {
                Text("\(Int(size.width))×\(Int(size.height))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if let compressed = item.compressedSize {
                    Text("\(fileSizeText) > \(String(format: "%.1f KB", Double(compressed) / 1024.0))")
                        .font(.caption2)
                        .foregroundColor(.green)
                } else {
                    Text(fileSizeText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

extension DispatchQueue {
    private static var _onceTracker = [String]()

    public class func once(token: String, block: () -> Void) {
        objc_sync_enter(self)
        defer { objc_sync_exit(self) }

        if _onceTracker.contains(token) {
            return
        }

        _onceTracker.append(token)
        block()
    }
}
