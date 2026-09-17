import AppKit
import Vision
import Combine

/// 画像 item を後追いで OCR し、結果を HistoryStore に書き戻す（低優先度・直列）
@MainActor
final class OCRQueue {
    private let store: HistoryStore
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .utility
        q.name = "obdist.hsp.clipnote.ocr"
        return q
    }()
    private var cancellable: AnyCancellable?
    private var inFlight: Set<UUID> = []

    init(store: HistoryStore) {
        self.store = store
        cancellable = store.imageAdded.sink { [weak self] item in self?.enqueue(item) }
        // 起動時: 未処理分を回収
        store.pendingOCR.forEach(enqueue)
    }

    func enqueue(_ item: ClipItem) {
        guard item.kind == .image, item.ocrText == nil, !inFlight.contains(item.id),
              let url = store.imageURL(for: item) else { return }
        inFlight.insert(item.id)
        let id = item.id
        queue.addOperation { [weak self] in
            let text = Self.recognize(url: url)
            Task { @MainActor in
                self?.inFlight.remove(id)
                self?.store.updateOCR(id: id, text: text ?? "")
            }
        }
    }

    nonisolated private static func recognize(url: URL) -> String? {
        guard let cg = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ja-JP", "en-US"]
        req.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([req]) } catch { return nil }
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}
