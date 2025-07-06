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
    @State private var isHoveringDropArea: Bool = false

    let compressionLevels = ["快", "中", "慢"]
    let outputFormats = ["JPEG", "WebP"]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    // Header Section
                    headerSection
                    
                    // Drop Area Section
                    dropAreaSection
                    
                    // Settings Section
                    settingsSection
                    
                    // Progress Section
                    progressSection
                    
                    // Action Buttons Section
                    actionButtonsSection
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(minWidth: 600, minHeight: 700)
            }
        }
        .background(backgroundGradient)
        .preferredColorScheme(isDarkMode ? .dark : .light)
        .onAppear {
            loadSettings()
        }
        .alert(LocalizedStringKey("alert_compression_failed"), isPresented: $showErrorAlert, actions: {
            Button(LocalizedStringKey("button_ok"), role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
        .sheet(isPresented: $showAbout) {
            aboutSheet
        }
    }
    
    // MARK: - Header Section
    private var headerSection: some View {
        VStack(spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NekoPress")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    
                    Text("智能圖片壓縮工具")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Dark Mode Toggle
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        isDarkMode.toggle()
                        saveSettings()
                    }
                }) {
                    Image(systemName: isDarkMode ? "moon.fill" : "sun.max.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isDarkMode ? .yellow : .orange)
                        .frame(width: 44, height: 44)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.primary.opacity(0.1))
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .contentShape(Rectangle())
            }
        }
    }
    
    // MARK: - Drop Area Section
    private var dropAreaSection: some View {
        VStack(spacing: 16) {
            ModernDropAreaView(
                images: $images,
                isHovering: $isHoveringDropArea
            )
            
            if !images.isEmpty {
                HStack {
                    Image(systemName: "photo.stack")
                        .foregroundColor(.blue)
                    Text("已選擇 \(images.count) 張圖片")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 4)
            }
        }
    }
    
    // MARK: - Settings Section
    private var settingsSection: some View {
        VStack(spacing: 20) {
            // Compression Level
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.blue)
                    Text("壓縮等級")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                
                ModernSegmentedControl(
                    selection: $compressionLevel,
                    options: compressionLevels,
                    onChange: { saveSettings() }
                )
            }
            
            // Output Format
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "doc.text")
                        .foregroundColor(.green)
                    Text("輸出格式")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                
                ModernSegmentedControl(
                    selection: $outputFormat,
                    options: outputFormats,
                    onChange: { saveSettings() }
                )
            }
            
            // Output Folder
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "folder")
                        .foregroundColor(.orange)
                    Text("輸出資料夾")
                        .font(.system(size: 16, weight: .semibold))
                    Spacer()
                }
                
                Button(action: selectOutputFolder) {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                            .foregroundColor(.white)
                        Text(outputFolderURL?.lastPathComponent ?? "選擇輸出資料夾")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.blue)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .contentShape(Rectangle())
            }
            
            // Backup Toggle
            HStack {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.purple)
                Text("備份原始檔案")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Toggle("", isOn: $shouldBackupOriginals)
                    .toggleStyle(SwitchToggleStyle(tint: .purple))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.primary.opacity(0.05))
        )
    }
    
    // MARK: - Progress Section
    private var progressSection: some View {
        VStack(spacing: 16) {
            if isCompressing {
                VStack(spacing: 12) {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                            .font(.system(size: 16))
                        Text("正在壓縮...")
                            .font(.system(size: 16, weight: .semibold))
                        Spacer()
                    }
                    
                    ProgressView(value: progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                        .scaleEffect(y: 1.5)
                    
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.blue.opacity(0.1))
                )
            }
            
            if originalTotalSize > 0 {
                let saved = originalTotalSize - compressedTotalSize
                let percent = Double(saved) / Double(originalTotalSize) * 100
                
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text(String(format: NSLocalizedString("text_saved_summary", comment: ""), Double(saved) / 1024.0, percent))
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.green)
                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.green.opacity(0.1))
                )
            }
        }
    }
    
    // MARK: - Action Buttons Section
    private var actionButtonsSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Start Compression Button
                Button(action: startCompression) {
                    HStack {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("開始壓縮")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(images.isEmpty || isCompressing ? Color.gray : Color.blue)
                    )
                }
                .disabled(images.isEmpty || isCompressing)
                .buttonStyle(PlainButtonStyle())
                .contentShape(Rectangle())
                
                // Cancel Button
                Button(action: cancelCompression) {
                    HStack {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 16, weight: .semibold))
                        Text("取消")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(!isCompressing ? Color.gray : Color.red)
                    )
                }
                .disabled(!isCompressing)
                .buttonStyle(PlainButtonStyle())
                .contentShape(Rectangle())
            }
            
            HStack(spacing: 12) {
                // Clear All Button
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        images.removeAll()
                    }
                }) {
                    HStack {
                        Image(systemName: "trash")
                            .font(.system(size: 14, weight: .medium))
                        Text("清除全部")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.red, lineWidth: 1)
                    )
                }
                .disabled(images.isEmpty)
                .buttonStyle(PlainButtonStyle())
                .contentShape(Rectangle())
                
                // About Button
                Button(action: { showAbout = true }) {
                    HStack {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .medium))
                        Text("關於")
                            .font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.blue)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.blue, lineWidth: 1)
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .contentShape(Rectangle())
            }
        }
    }
    
    // MARK: - Background Gradient
    private var backgroundGradient: some View {
        LinearGradient(
            gradient: Gradient(colors: [
                Color.primary.opacity(0.02),
                Color.primary.opacity(0.01),
                Color.primary.opacity(0.02)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
    
    // MARK: - About Sheet
    private var aboutSheet: some View {
        VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 48))
                    .foregroundColor(.blue)
                
                Text("NekoPress")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                
                Text("智能圖片壓縮工具")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
            }
            
            VStack(spacing: 8) {
                Text("版本 1.0")
                    .font(.system(size: 14, weight: .medium))
                
                Text("支援語言：繁體中文、English、日本語")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
            
            Button("關閉") {
                showAbout = false
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue)
            )
            .buttonStyle(PlainButtonStyle())
            .contentShape(Rectangle())
        }
        .padding(24)
        .frame(width: 320, height: 280)
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

// MARK: - Modern Drop Area View
struct ModernDropAreaView: View {
    @Binding var images: [CompressImage]
    @Binding var isHovering: Bool
    
    var body: some View {
        VStack(spacing: 16) {
            if images.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 48))
                        .foregroundColor(.blue)
                        .opacity(isHovering ? 0.8 : 0.6)
                    
                    VStack(spacing: 8) {
                        Text("拖拽圖片到此處")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                        
                        Text("支援 JPG、PNG、BMP、HEIC 格式")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(height: 200)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            isHovering ? Color.blue : Color.gray.opacity(0.3),
                            lineWidth: isHovering ? 2 : 1
                        )
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(isHovering ? Color.blue.opacity(0.05) : Color.clear)
                        )
                )
                .scaleEffect(isHovering ? 1.02 : 1.0)
                .animation(.easeInOut(duration: 0.2), value: isHovering)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(Array(images.enumerated()), id: \.offset) { index, item in
                            ModernImagePreview(index: index, item: item)
                        }
                    }
                    .padding(.horizontal, 4)
                }
                .frame(height: 200)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isHovering) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { item, error in
                    guard let url = item, error == nil else { return }

                    let allowedExtensions = ["jpg", "jpeg", "png", "bmp", "heic", "heif"]
                    guard allowedExtensions.contains(url.pathExtension.lowercased()) else { return }

                    DispatchQueue.main.async {
                        let imageItem = CompressImage(url: url)
                        withAnimation(.easeInOut(duration: 0.3)) {
                            images.append(imageItem)
                        }
                    }
                }
            }
            return true
        }
    }
}

// MARK: - Modern Image Preview
struct ModernImagePreview: View {
    let index: Int
    let item: CompressImage
    
    var body: some View {
        VStack(spacing: 8) {
            let nsImage = NSImage(contentsOf: item.url) ?? NSImage(size: .zero)
            let size = nsImage.size
            let fileSizeText: String = {
                if let resourceValues = try? item.url.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resourceValues.fileSize {
                    return String(format: "%.1f KB", Double(fileSize) / 1024.0)
                }
                return ""
            }()
            
            ZStack {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipped()
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                
                if let compressed = item.compressedSize {
                    VStack {
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 16))
                                .background(Circle().fill(.white))
                        }
                        Spacer()
                    }
                    .padding(8)
                }
            }
            
            VStack(spacing: 4) {
                Text("\(Int(size.width))×\(Int(size.height))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                
                if let compressed = item.compressedSize {
                    Text("\(fileSizeText) → \(String(format: "%.1f KB", Double(compressed) / 1024.0))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.green)
                } else {
                    Text(fileSizeText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

// MARK: - Modern Segmented Control
struct ModernSegmentedControl: View {
    @Binding var selection: String
    let options: [String]
    let onChange: () -> Void
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.self) { option in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection = option
                        onChange()
                    }
                }) {
                    Text(option)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(selection == option ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selection == option ? Color.blue : Color.clear)
                        )
                }
                .buttonStyle(PlainButtonStyle())
                .contentShape(Rectangle())
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.1))
        )
    }
}

#Preview {
    ContentView()
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
