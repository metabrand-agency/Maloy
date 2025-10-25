//
//  TextbookManager.swift
//  Maloy
//
//  PDF textbook reader with GPT-4o Vision integration
//  Allows reading scanned textbooks and solving homework problems
//

import Foundation
import PDFKit
import UIKit

class TextbookManager {

    // MARK: - Properties

    /// Path to iCloud Documents directory where textbooks are stored
    private var textbooksDirectory: URL? {
        // Get app-specific iCloud container
        guard let appContainer = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            print("⚠️ iCloud not available")
            return nil
        }

        print("📂 App container: \(appContainer.path)")

        // Navigate to general iCloud Drive (com~apple~CloudDocs)
        // Path structure: .../Mobile Documents/iCloud~Metabrand~Maloy2
        // We want:        .../Mobile Documents/com~apple~CloudDocs
        let baseDir = appContainer.deletingLastPathComponent()
        let iCloudDrive = baseDir.appendingPathComponent("com~apple~CloudDocs")

        print("📂 iCloud Drive: \(iCloudDrive.path)")
        print("📂 iCloud Drive exists: \(FileManager.default.fileExists(atPath: iCloudDrive.path))")

        // Try different paths where user might have put textbooks
        let pathsToTry = [
            iCloudDrive.appendingPathComponent("Maloy"),
            iCloudDrive.appendingPathComponent("Documents").appendingPathComponent("Textbooks"),
            appContainer.appendingPathComponent("Documents").appendingPathComponent("Textbooks"),
        ]

        for (index, path) in pathsToTry.enumerated() {
            print("📂 Path \(index + 1): \(path.path)")
            if FileManager.default.fileExists(atPath: path.path) {
                print("✅ FOUND at path \(index + 1)!")

                // List all files
                if let files = try? FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil) {
                    print("📂 Files: \(files.map { $0.lastPathComponent })")
                }

                return path
            } else {
                print("   ❌ Not found")
            }
        }

        print("⚠️ No textbooks found in any location")
        return pathsToTry[0]
    }

    /// Cache for loaded PDFs to avoid reloading
    private var pdfCache: [String: PDFDocument] = [:]

    /// Cache for recognized text to save API calls
    private var textCache: [String: String] = [:]

    private let openAIKey: String

    /// Remote textbook URLs (Dropbox)
    private let remoteTextbooks: [String: String] = [
        "Физика 8 класс": "https://www.dropbox.com/scl/fi/naf0ab8nfe600tmjax53m/8.pdf?rlkey=jo9csynj3fjtrehypn7ch6ond&dl=1",
        "Алгебра 8 класс": "https://www.dropbox.com/scl/fi/lo0xmo83hj221k03co460/8.pdf?rlkey=r2dralul78x566s0bqse6kaky&dl=1",
        "Химия 8 класс": "https://www.dropbox.com/scl/fi/mi4w8jz6c4537fabzdg5n/8.pdf?rlkey=ih5krtmjmhk8086phb9xlaz3m&dl=1",
        "Теория вероятности 8 класс": "https://www.dropbox.com/scl/fi/aqakummvycdswqbwe8znf/8.pdf?rlkey=c7s5p9ce63phgv7ewzx17bkku&dl=1"
    ]

    /// Local cache directory for downloaded textbooks
    private var localCacheDirectory: URL? {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return cacheDir?.appendingPathComponent("Textbooks")
    }

    // MARK: - Initialization

    init(apiKey: String) {
        self.openAIKey = apiKey
        print("📚 TextbookManager initialized")
        setupLocalCache()
    }

    /// Create local cache directory for downloaded textbooks
    private func setupLocalCache() {
        guard let cacheDir = localCacheDirectory else {
            print("⚠️ Cannot get cache directory")
            return
        }

        if !FileManager.default.fileExists(atPath: cacheDir.path) {
            do {
                try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                print("✅ Created local textbooks cache: \(cacheDir.path)")
            } catch {
                print("❌ Failed to create cache directory: \(error)")
            }
        } else {
            print("✅ Local textbooks cache exists: \(cacheDir.path)")
        }
    }

    /// Create textbooks directory in iCloud if it doesn't exist
    private func setupTextbooksDirectory() {
        guard let dir = textbooksDirectory else {
            print("⚠️ iCloud not available")
            return
        }

        if !FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                print("✅ Created textbooks directory: \(dir.path)")
            } catch {
                print("❌ Failed to create textbooks directory: \(error)")
            }
        } else {
            print("✅ Textbooks directory exists: \(dir.path)")
        }
    }

    // MARK: - PDF Loading

    /// List all available textbooks
    func listTextbooks() -> [String] {
        // Return list of remote textbooks (always available)
        let textbooks = Array(remoteTextbooks.keys).sorted()
        print("📚 Available textbooks from Dropbox: \(textbooks)")
        return textbooks
    }

    /// Download textbook from Dropbox if needed
    private func downloadTextbookIfNeeded(named name: String, completion: @escaping (URL?) -> Void) {
        guard let cacheDir = localCacheDirectory else {
            print("❌ No cache directory")
            completion(nil)
            return
        }

        let localPath = cacheDir.appendingPathComponent("\(name).pdf")

        // Check if already downloaded
        if FileManager.default.fileExists(atPath: localPath.path) {
            print("✅ Textbook already cached: \(name)")
            completion(localPath)
            return
        }

        // Get download URL
        guard let downloadURL = remoteTextbooks[name],
              let url = URL(string: downloadURL) else {
            print("❌ No download URL for: \(name)")
            completion(nil)
            return
        }

        print("📥 Downloading \(name) from Dropbox...")

        // Download file
        URLSession.shared.downloadTask(with: url) { tempURL, response, error in
            if let error = error {
                print("❌ Download error: \(error)")
                completion(nil)
                return
            }

            guard let tempURL = tempURL else {
                print("❌ No temp file")
                completion(nil)
                return
            }

            do {
                // Move to cache directory
                try FileManager.default.moveItem(at: tempURL, to: localPath)
                print("✅ Downloaded and cached: \(name)")
                completion(localPath)
            } catch {
                print("❌ Failed to save: \(error)")
                completion(nil)
            }
        }.resume()
    }

    /// Load a PDF document by name
    private func loadPDF(named name: String, completion: @escaping (PDFDocument?) -> Void) {
        // Check memory cache first
        if let cached = pdfCache[name] {
            print("✅ Using cached PDF from memory: \(name)")
            completion(cached)
            return
        }

        // Download if needed and load
        downloadTextbookIfNeeded(named: name) { [weak self] localURL in
            guard let self = self, let url = localURL else {
                completion(nil)
                return
            }

            guard let document = PDFDocument(url: url) else {
                print("❌ Failed to load PDF: \(name)")
                completion(nil)
                return
            }

            print("✅ Loaded PDF: \(name) (\(document.pageCount) pages)")
            self.pdfCache[name] = document
            completion(document)
        }
    }

    // MARK: - Page Extraction

    /// Extract specific pages as images for Vision API
    func extractPages(from textbookName: String, pages: [Int], completion: @escaping ([UIImage]) -> Void) {
        loadPDF(named: textbookName) { pdf in
            guard let pdf = pdf else {
                print("❌ Could not load textbook: \(textbookName)")
                completion([])
                return
            }

            var images: [UIImage] = []

            for pageNumber in pages {
                guard pageNumber > 0 && pageNumber <= pdf.pageCount else {
                    print("⚠️ Page \(pageNumber) out of range (1-\(pdf.pageCount))")
                    continue
                }

                // PDF pages are 0-indexed
                guard let page = pdf.page(at: pageNumber - 1) else {
                    print("❌ Failed to get page \(pageNumber)")
                    continue
                }

                // Render page to image
                let pageRect = page.bounds(for: .mediaBox)
                let renderer = UIGraphicsImageRenderer(size: pageRect.size)

                let image = renderer.image { ctx in
                    UIColor.white.set()
                    ctx.fill(pageRect)

                    ctx.cgContext.translateBy(x: 0, y: pageRect.size.height)
                    ctx.cgContext.scaleBy(x: 1.0, y: -1.0)

                    page.draw(with: .mediaBox, to: ctx.cgContext)
                }

                images.append(image)
                print("✅ Extracted page \(pageNumber) from \(textbookName)")
            }

            completion(images)
        }
    }

    // MARK: - GPT-4o Vision Integration

    /// Read pages using GPT-4o Vision API
    func readPages(
        textbookName: String,
        pages: [Int],
        instruction: String = "Read all the text on these pages, including formulas and diagrams.",
        completion: @escaping (Bool, String) -> Void
    ) {
        // Create cache key
        let cacheKey = "\(textbookName)_pages_\(pages.sorted().map(String.init).joined(separator: "_"))"

        // Check cache first
        if let cachedText = textCache[cacheKey] {
            print("✅ Using cached text for \(cacheKey)")
            completion(true, cachedText)
            return
        }

        // Extract pages as images (now async)
        extractPages(from: textbookName, pages: pages) { [weak self] images in
            guard let self = self else { return }

            guard !images.isEmpty else {
                completion(false, "Не удалось извлечь страницы из учебника")
                return
            }

        // Convert images to base64
        var imageBase64Strings: [String] = []
        for image in images {
            guard let imageData = image.jpegData(compressionQuality: 0.8) else {
                print("❌ Failed to convert image to JPEG")
                continue
            }
            let base64String = imageData.base64EncodedString()
            imageBase64Strings.append(base64String)
        }

        guard !imageBase64Strings.isEmpty else {
            completion(false, "Не удалось преобразовать страницы")
            return
        }

        print("📤 Sending \(imageBase64Strings.count) pages to GPT-4o Vision")

            // Call GPT-4o Vision API
            self.callVisionAPI(imageBase64: imageBase64Strings, instruction: instruction) { success, text in
                if success {
                    // Cache the result
                    self.textCache[cacheKey] = text
                    print("✅ Cached result for \(cacheKey)")
                }
                completion(success, text)
            }
        }
    }

    /// Call OpenAI GPT-4o Vision API
    private func callVisionAPI(
        imageBase64: [String],
        instruction: String,
        completion: @escaping (Bool, String) -> Void
    ) {
        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            completion(false, "Invalid API URL")
            return
        }

        // Build content array with instruction and images
        var content: [[String: Any]] = [
            ["type": "text", "text": instruction]
        ]

        for base64 in imageBase64 {
            content.append([
                "type": "image_url",
                "image_url": [
                    "url": "data:image/jpeg;base64,\(base64)"
                ]
            ])
        }

        let json: [String: Any] = [
            "model": "gpt-4o",
            "messages": [
                [
                    "role": "user",
                    "content": content
                ]
            ],
            "max_tokens": 4096
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(openAIKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: json)

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                print("❌ Vision API error: \(error)")
                completion(false, "Ошибка API")
                return
            }

            guard let data = data else {
                print("❌ No data from Vision API")
                completion(false, "Нет данных")
                return
            }

            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = json["choices"] as? [[String: Any]],
                      let firstChoice = choices.first,
                      let message = firstChoice["message"] as? [String: Any],
                      let text = message["content"] as? String else {
                    print("❌ Failed to parse Vision API response")
                    if let responseString = String(data: data, encoding: .utf8) {
                        print("Response: \(responseString)")
                    }
                    completion(false, "Ошибка парсинга ответа")
                    return
                }

                print("✅ Vision API success, got \(text.count) characters")
                completion(true, text)

            } catch {
                print("❌ JSON parse error: \(error)")
                completion(false, "Ошибка парсинга")
            }
        }.resume()
    }

    // MARK: - Helper Methods

    /// Get debug info about textbooks source
    func getDebugInfo() -> String {
        let cachedCount = (try? FileManager.default.contentsOfDirectory(at: localCacheDirectory!, includingPropertiesForKeys: nil).count) ?? 0
        return "Учебники загружаются из Dropbox. Кешировано локально: \(cachedCount) файлов"
    }

    /// Find textbook by subject name (fuzzy matching)
    func findTextbook(subject: String) -> String? {
        print("🔍 Finding textbook for subject: '\(subject)'")
        let textbooks = listTextbooks()
        print("🔍 Available textbooks: \(textbooks)")
        let subjectLower = subject.lowercased()

        // Exact match first
        if let exact = textbooks.first(where: { $0.lowercased().contains(subjectLower) }) {
            print("✅ Found exact match: '\(exact)'")
            return exact
        }

        // Try partial matches
        let keywords = ["физика", "алгебра", "геометрия", "история", "биология", "химия", "русский", "литература", "английский", "вероятность"]
        print("🔍 Trying keyword matching with: \(keywords)")
        for keyword in keywords {
            if subjectLower.contains(keyword) {
                print("🔍 Subject contains keyword: '\(keyword)'")
                if let match = textbooks.first(where: { $0.lowercased().contains(keyword) }) {
                    print("✅ Found keyword match: '\(match)'")
                    return match
                }
            }
        }

        print("❌ No textbook found for subject: '\(subject)'")
        return nil
    }
}
