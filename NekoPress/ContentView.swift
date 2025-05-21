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

    let compressionLevels = ["快", "中", "慢"]
    let outputFormats = ["JPEG", "WebP"]

var body: some View {
        VStack(spacing: 16) {
            Toggle("夜間模式", isOn: $isDarkMode)
                .padding(.horizontal)

            DropAreaView(images: $images)

            VStack(spacing: 4) {
                Text("壓縮等級會影響畫質與檔案大小：快 → 壓縮多但畫質差，慢 → 壓縮少但畫質好")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)

                Picker("壓縮等級", selection: $compressionLevel) {
                    ForEach(compressionLevels, id: \.self) { level in
                        Text(level)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .onChange(of: compressionLevel) { _ in
                    saveSettings()
                }

                Picker("輸出格式", selection: $outputFormat) {
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

            Button("選擇輸出資料夾") {
                selectOutputFolder()
            }
            .padding(.top, 8)

            Toggle("備份原圖到 Origin 資料夾", isOn: $shouldBackupOriginals)
                .padding(.horizontal)

            ProgressView(value: progress)
                .padding(.horizontal)

            if originalTotalSize > 0 {
                let saved = originalTotalSize - compressedTotalSize
                let percent = Double(saved) / Double(originalTotalSize) * 100
                Text(String(format: "總共減少 %.2f KB（%.1f%%）", Double(saved) / 1024.0, percent))
                    .font(.subheadline)
                    .foregroundColor(.green)
            }

            HStack {
                Button("開始壓縮") {
                    startCompression()
                }
                .disabled(images.isEmpty || isCompressing)

                Button("取消壓縮") {
                    cancelCompression()
                }
                .disabled(!isCompressing)
            }
            .padding(.horizontal)

            Button("清除所有圖片") {
                images.removeAll()
            }
            .padding(.bottom, 8)
        }
        .padding()
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear {
            loadSettings()
        }
        .alert("壓縮失敗", isPresented: $showErrorAlert, actions: {
            Button("確定", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
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

        originalTotalSize = images.reduce(0) { total, item in
            if let resourceValues = try? item.url.resourceValues(forKeys: [.fileSizeKey]),
               let fileSize = resourceValues.fileSize {
                return total + fileSize
            }
            return total
        }
        compressedTotalSize = 0

        let total = images.count
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "compression.queue", attributes: .concurrent)

        for (index, item) in images.enumerated() {
            queue.async(group: group) {
                if cancelRequested {
                    return
                }

                let baseDirectory: URL
                if let customOutput = outputFolderURL {
                    baseDirectory = customOutput
                } else {
                    baseDirectory = item.url.deletingLastPathComponent()
                }

                // 根據 outputFormat 決定副檔名與寫入格式
                let ext = outputFormat.lowercased()
                let baseName: String
                if FileManager.default.fileExists(atPath: item.url.path) {
                    baseName = item.url.deletingPathExtension().lastPathComponent
                } else {
                    baseName = "image_\(index)"
                }
                let filename = "\(baseName)_compressed.\(ext)"
                let fileURL = baseDirectory.appendingPathComponent(filename)

                // 直接用 CGImageSource 讀取 CGImage
                guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    DispatchQueue.main.async {
                        errorMessage = "無法載入圖片：\(item.url.lastPathComponent)"
                        showErrorAlert = true
                    }
                    return
                }

                var imageData: Data?
                switch outputFormat {
                case "JPEG":
                    let quality: CGFloat
                    switch compressionLevel {
                    case "快":
                        quality = 0.1
                    case "中":
                        quality = 0.3
                    case "慢":
                        quality = 0.5
                    default:
                        quality = 0.3
                    }
                    // 用 CGImage 轉 NSBitmapImageRep
                    let bitmap = NSBitmapImageRep(cgImage: cgImage)
                    imageData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality])
                case "WebP":
                    let quality: CGFloat
                    switch compressionLevel {
                    case "快":
                        quality = 0.2
                    case "中":
                        quality = 0.5
                    case "慢":
                        quality = 0.8
                    default:
                        quality = 0.5
                    }
                    // 縮圖（CGImage流程），建立 NSImage 包裝 CGImage 再交給 WebPCoder
                    let resized = downscaleCGImage(cgImage, maxDimension: 2048) ?? cgImage
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
                    do {
                        try data.write(to: fileURL)
                        DispatchQueue.main.async {
                            compressedTotalSize += data.count
                            images[index].compressedSize = data.count
                            progress = Double(index + 1) / Double(total)
                        }
                    } catch {
                        DispatchQueue.main.async {
                            errorMessage = "無法寫入檔案：\(fileURL.lastPathComponent)"
                            showErrorAlert = true
                        }
                    }
                }

                // 再進行原圖備份
                if shouldBackupOriginals {
                    let originFolder = item.url.deletingLastPathComponent().appendingPathComponent("Origin", isDirectory: true)
                    try? FileManager.default.createDirectory(at: originFolder, withIntermediateDirectories: true)
                    let backupURL = originFolder.appendingPathComponent(item.url.lastPathComponent)
                    try? FileManager.default.moveItem(at: item.url, to: backupURL)
                }
            }
        }
        group.notify(queue: .main) {
            isCompressing = false
        }
    }

    func cancelCompression() {
        cancelRequested = true
        isCompressing = false
    }

    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(compressionLevel, forKey: "compressionLevel")
        defaults.set(outputFormat, forKey: "outputFormat")
    }

    func loadSettings() {
        let defaults = UserDefaults.standard
        if let savedLevel = defaults.string(forKey: "compressionLevel") {
            compressionLevel = savedLevel
        }
        if let savedFormat = defaults.string(forKey: "outputFormat") {
            outputFormat = savedFormat
        }
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
                        Text("拖曳圖片到此處")
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
