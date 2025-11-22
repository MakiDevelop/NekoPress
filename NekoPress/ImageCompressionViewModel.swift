//
//  ImageCompressionViewModel.swift
//  NekoPress
//
//  Created by Claude Code on 2025/10/24.
//

import Foundation
import SwiftUI
import AppKit
import SDWebImage
import SDWebImageWebPCoder
import CoreImage
import ImageIO

// MARK: - Models (Reference from ContentView)
// CompressImage and CompressionUpdate are defined in ContentView.swift

// MARK: - Actor for Thread-Safe Update Management
actor UpdateManager {
    private var pendingUpdates: [CompressionUpdate] = []

    func addUpdate(_ update: CompressionUpdate) {
        pendingUpdates.append(update)
    }

    func drainUpdates() -> [CompressionUpdate] {
        let updates = pendingUpdates
        pendingUpdates.removeAll()
        return updates
    }
}

// MARK: - View Model
@MainActor
class ImageCompressionViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var isDarkMode: Bool = false
    @Published var compressionLevel: String = "medium"
    @Published var outputFormat: String = "JPEG"
    @Published var outputFolderURL: URL? = nil
    @Published var progress: Double = 0.0
    @Published var isCompressing: Bool = false
    @Published var images: [CompressImage] = []
    @Published var originalTotalSize: Int = 0
    @Published var compressedTotalSize: Int = 0
    @Published var shouldDeleteSourceFiles: Bool = false
    @Published var showErrorAlert: Bool = false
    @Published var errorMessage: String = ""
    @Published var showAbout: Bool = false

    // MARK: - Private Properties
    private var completedCount: Int = 0
    private var cancelRequested: Bool = false
    private let updateManager = UpdateManager()

    // Constants
    let compressionLevels = ["fast", "medium", "slow"]
    let outputFormats = ["JPEG", "WebP"]

    // MARK: - Helper Functions
    func compressionLevelDisplayName(_ level: String) -> String {
        switch level {
        case "fast": return NSLocalizedString("compression_level_fast", comment: "")
        case "medium": return NSLocalizedString("compression_level_medium", comment: "")
        case "slow": return NSLocalizedString("compression_level_slow", comment: "")
        default: return level
        }
    }

    // MARK: - Settings Management
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(compressionLevel, forKey: "compressionLevel")
        defaults.set(outputFormat, forKey: "outputFormat")
        defaults.set(isDarkMode, forKey: "isDarkMode")
        defaults.set(shouldDeleteSourceFiles, forKey: "shouldDeleteSourceFiles")
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
        if defaults.object(forKey: "shouldDeleteSourceFiles") != nil {
            shouldDeleteSourceFiles = defaults.bool(forKey: "shouldDeleteSourceFiles")
        } else {
            shouldDeleteSourceFiles = defaults.bool(forKey: "shouldBackupOriginals")
        }
    }

    // MARK: - Image Management
    func addImage(_ url: URL) {
        let cachedImage = NSImage(contentsOf: url)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        var imageItem = CompressImage(url: url)
        imageItem.image = cachedImage
        imageItem.originalFileSize = fileSize
        images.append(imageItem)
    }

    func clearAllImages() {
        images.removeAll()
    }

    // MARK: - Compression
    func startCompression() {
        DispatchQueue.once(token: "com.nekopress.webp") {
            SDImageCodersManager.shared.addCoder(SDImageWebPCoder.shared)
        }

        guard !images.isEmpty else { return }
        cancelRequested = false
        isCompressing = true
        progress = 0.0
        completedCount = 0

        Task {
            _ = await updateManager.drainUpdates()
        }

        // 計算原始總大小
        originalTotalSize = images.reduce(0) { total, item in
            if let resourceValues = try? item.url.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                return total + fileSize
            }
            return total
        }
        compressedTotalSize = 0

        // 使用 Swift Concurrency 進行並行處理
        Task {
            await performCompression()
        }
    }

    private func performCompression() async {
        let maxConcurrency = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)

        // 啟動 UI 更新任務
        let updateTask = Task {
            await startPeriodicUpdate()
        }

        await withTaskGroup(of: Void.self) { group in
            var activeTaskCount = 0

            for (index, item) in images.enumerated() {
                // 檢查是否取消
                if cancelRequested { break }

                // 控制並發數量
                while activeTaskCount >= maxConcurrency {
                    _ = await group.next()
                    activeTaskCount -= 1
                }

                group.addTask { [self] in
                    await processImage(item: item, index: index)
                }
                activeTaskCount += 1
            }

            // 等待所有任務完成
            await group.waitForAll()
        }

        // 停止更新任務
        updateTask.cancel()
        await finalUpdate()

        isCompressing = false
    }

    private func processImage(item: CompressImage, index: Int) async {
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
            errorMessage = String(format: NSLocalizedString("error_cannot_load_image", comment: ""), item.url.lastPathComponent)
            showErrorAlert = true
            return
        }

        var imageData: Data?
        switch outputFormat {
        case "JPEG":
            let quality: CGFloat
            switch compressionLevel {
            case "fast": quality = 0.1
            case "medium": quality = 0.3
            case "slow": quality = 0.5
            default: quality = 0.3
            }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            imageData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
        case "WebP":
            let quality: CGFloat
            switch compressionLevel {
            case "fast": quality = 0.3
            case "medium": quality = 0.7
            case "slow": quality = 0.95
            default: quality = 0.7
            }
            let resized = ImageProcessor.shared.downscaleCGImage(cgImage, maxDimension: 2048) ?? cgImage
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

        guard let data = imageData else { return }

        do {
            // 寫入壓縮後的檔案
            try data.write(to: fileURL)

            if shouldDeleteSourceFiles {
                do {
                    try FileManager.default.removeItem(at: item.url)
                } catch {
                    errorMessage = String(format: NSLocalizedString("error_cannot_delete_file", comment: ""), item.url.lastPathComponent)
                    showErrorAlert = true
                }
            }

            // 將更新加入隊列
            await addUpdate(
                index: index,
                compressedSize: data.count,
                totalSize: data.count
            )
        } catch {
            errorMessage = String(format: NSLocalizedString("error_cannot_write_file", comment: ""), fileURL.lastPathComponent)
            showErrorAlert = true
        }
    }

    // 週期性更新 UI
    private func startPeriodicUpdate() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)  // 0.2 秒
            await updateUI()
        }
    }

    // 最終更新
    private func finalUpdate() async {
        await updateUI()
    }

    // 添加更新（線程安全）
    private func addUpdate(index: Int, compressedSize: Int, totalSize: Int) async {
        let update = CompressionUpdate(index: index, compressedSize: compressedSize, totalSize: totalSize)
        await updateManager.addUpdate(update)
    }

    // 更新 UI（在主線程）
    private func updateUI() async {
        let updates = await updateManager.drainUpdates()

        guard !updates.isEmpty else { return }

        for update in updates {
            self.compressedTotalSize += update.totalSize
            self.images[update.index].compressedSize = update.compressedSize
            self.completedCount += 1
        }
        self.progress = Double(self.completedCount) / Double(self.images.count)
    }

    func cancelCompression() {
        cancelRequested = true
        isCompressing = false
    }
}

// MARK: - Image Processor
class ImageProcessor {
    static let shared = ImageProcessor()
    private let sharedCIContext = CIContext()

    private init() {}

    func downscaleCGImage(_ input: CGImage, maxDimension: CGFloat) -> CGImage? {
        let width = CGFloat(input.width)
        let height = CGFloat(input.height)
        let ratio = min(maxDimension / width, maxDimension / height, 1.0)

        let transform = CGAffineTransform(scaleX: ratio, y: ratio)
        let ciImage = CIImage(cgImage: input).transformed(by: transform)
        let rect = CGRect(origin: .zero, size: CGSize(width: width * ratio, height: height * ratio))

        return sharedCIContext.createCGImage(ciImage, from: rect)
    }
}
