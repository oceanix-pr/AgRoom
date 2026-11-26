import Foundation
import Vision
import CoreGraphics
import AppKit
import ScreenCaptureKit

// MARK: - OCR Service

/// OCR 服务：系统 Vision 框架识别（简体中文 + 英文），支持文件/剪贴板/屏幕截图来源
public enum OCRService {
    public static let maximumImagePixels = 40_000_000
    public static let recognitionDimension = 4096

    public enum OCRError: LocalizedError {
        case cannotLoadImage
        case noTextFound
        case screenCaptureNotPermitted

        public var errorDescription: String? {
            switch self {
            case .cannotLoadImage:
                return "Cannot load image data."
            case .noTextFound:
                return "No text was found in the image."
            case .screenCaptureNotPermitted:
                return "Screen capture permission is required. Please grant it in System Settings → Privacy & Security."
            }
        }
    }

    /// 支持的图片扩展名
    public static let supportedExtensions = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"]

    // MARK: - Recognition

    /// 识别 CGImage 中的文字（按阅读顺序逐行返回）
    public static func recognize(cgImage: CGImage) throws -> String {
        try validateDimensions(width: cgImage.width, height: cgImage.height)
        let request = VNRecognizeTextRequest()
        return try perform(cgImage, request: request)
    }

    private static func perform(_ image: CGImage, request: VNRecognizeTextRequest) throws -> String {
        try Task.checkCancellation()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        try Task.checkCancellation()

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else {
            throw OCRError.noTextFound
        }
        return lines.joined(separator: "\n")
    }

    /// Vision cancellation is forwarded to the actual request; decoding and recognition stay off the main actor.
    public static func recognizeCancellable(cgImage: CGImage) async throws -> String {
        try validateDimensions(width: cgImage.width, height: cgImage.height)
        let input = RecognitionInput(image: cgImage)
        return try await TaskDeadline.run(until: Date().addingTimeInterval(60)) {
            let job = Task.detached { try perform(input.image, request: input.request) }
            return try await withTaskCancellationHandler {
                try await job.value
            } onCancel: { input.request.cancel(); job.cancel() }
        }
    }

    public static func recognizeCancellable(imageData: Data) async throws -> String {
        let image = try await Task.detached {
            try Task.checkCancellation()
            guard imageData.count <= 32 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { throw OCRError.cannotLoadImage }
            return try boundedImage(source)
        }.value
        return try await recognizeCancellable(cgImage: image)
    }

    public static func recognizeCancellable(imageURL: URL) async throws -> String {
        let data = try await Task.detached {
            try Task.checkCancellation()
            let values = try imageURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 32 * 1024 * 1024 else { throw OCRError.cannotLoadImage }
            let handle = try FileHandle(forReadingFrom: imageURL)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 32 * 1024 * 1024 + 1) ?? Data()
            guard data.count <= 32 * 1024 * 1024 else { throw OCRError.cannotLoadImage }
            return data
        }.value
        return try await recognizeCancellable(imageData: data)
    }

    static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= maximumImagePixels / height else { throw OCRError.cannotLoadImage }
    }

    private final class RecognitionInput: @unchecked Sendable {
        let image: CGImage
        let request = VNRecognizeTextRequest()
        init(image: CGImage) { self.image = image }
    }

    /// 识别图片文件
    public static func recognize(imageURL: URL) throws -> String {
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else {
            throw OCRError.cannotLoadImage
        }
        return try recognize(cgImage: boundedImage(source))
    }

    /// 识别图片数据（剪贴板等）
    public static func recognize(imageData: Data) throws -> String {
        guard imageData.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw OCRError.cannotLoadImage
        }
        return try recognize(cgImage: boundedImage(source))
    }

    /// 从 NSImage 识别（兼容多表示格式）
    public static func recognize(nsImage: NSImage) throws -> String {
        guard let tiff = nsImage.tiffRepresentation else {
            throw OCRError.cannotLoadImage
        }
        return try recognize(imageData: tiff)
    }

    static func boundedImage(_ source: CGImageSource) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= maximumImagePixels / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: recognitionDimension,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { throw OCRError.cannotLoadImage }
        return image
    }

    // MARK: - Screen Capture

    /// 屏幕录制权限预检（规范：调用前先 preflight）
    public static var screenCapturePermitted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// 请求屏幕录制权限（异步，授权后需提示重启生效由 UI 处理）
    @discardableResult
    public static func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// 截取主显示器全屏（ScreenCaptureKit；需屏幕录制权限，调用前已 preflight）
    public static func captureMainDisplay() async throws -> CGImage {
        guard screenCapturePermitted else {
            throw OCRError.screenCaptureNotPermitted
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
            ?? content.displays.first else {
            throw OCRError.cannotLoadImage
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        let width = CGDisplayPixelsWide(display.displayID)
        let height = CGDisplayPixelsHigh(display.displayID)
        guard width > 0, height > 0 else { throw OCRError.cannotLoadImage }
        let scale = min(1, Double(recognitionDimension) / Double(max(width, height)))
        config.width = max(1, Int(Double(width) * scale))
        config.height = max(1, Int(Double(height) * scale))
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// 按屏幕坐标从全屏截图中裁剪区域（points → pixels 换算）
    public static func crop(_ image: CGImage, regionInPoints: CGRect, screenFrameInPoints: CGRect) -> CGImage? {
        guard screenFrameInPoints.width > 0, screenFrameInPoints.height > 0 else { return nil }
        let scaleX = CGFloat(image.width) / screenFrameInPoints.width
        let scaleY = CGFloat(image.height) / screenFrameInPoints.height
        // 屏幕坐标原点在左下，图像坐标原点在左上，需翻转 Y
        let pixelRect = CGRect(
            x: (regionInPoints.minX - screenFrameInPoints.minX) * scaleX,
            y: (screenFrameInPoints.maxY - regionInPoints.maxY) * scaleY,
            width: regionInPoints.width * scaleX,
            height: regionInPoints.height * scaleY
        ).integral
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }
}
