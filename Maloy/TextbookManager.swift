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
        FileManager.default.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents")
            .appendingPathComponent("Textbooks")
    }

    /// Cache for loaded PDFs to avoid reloading
    private var pdfCache: [String: PDFDocument] = [:]

    /// Cache for recognized text to save API calls
    private var textCache: [String: String] = [:]

    private let openAIKey: String

    // MARK: - Initialization

    init(apiKey: String) {
        self.openAIKey = apiKey
        print("📚 TextbookManager initialized")
        setupTextbooksDirectory()
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
        guard let dir = textbooksDirectory else { return [] }

        do {
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            let pdfFiles = files.filter { $0.pathExtension.lowercased() == "pdf" }
                .map { $0.deletingPathExtension().lastPathComponent }
            print("📚 Found \(pdfFiles.count) textbooks: \(pdfFiles)")
            return pdfFiles
        } catch {
            print("❌ Failed to list textbooks: \(error)")
            return []
        }
    }

    /// Load a PDF document by name
    private func loadPDF(named name: String) -> PDFDocument? {
        // Check cache first
        if let cached = pdfCache[name] {
            print("✅ Using cached PDF: \(name)")
            return cached
        }

        guard let dir = textbooksDirectory else {
            print("❌ iCloud directory not available")
            return nil
        }

        let pdfURL = dir.appendingPathComponent("\(name).pdf")

        guard let document = PDFDocument(url: pdfURL) else {
            print("❌ Failed to load PDF: \(name)")
            return nil
        }

        print("✅ Loaded PDF: \(name) (\(document.pageCount) pages)")
        pdfCache[name] = document
        return document
    }

    // MARK: - Page Extraction

    /// Extract specific pages as images for Vision API
    func extractPages(from textbookName: String, pages: [Int]) -> [UIImage] {
        guard let pdf = loadPDF(named: textbookName) else {
            print("❌ Could not load textbook: \(textbookName)")
            return []
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

        return images
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

        // Extract pages as images
        let images = extractPages(from: textbookName, pages: pages)

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
        callVisionAPI(imageBase64: imageBase64Strings, instruction: instruction) { success, text in
            if success {
                // Cache the result
                self.textCache[cacheKey] = text
                print("✅ Cached result for \(cacheKey)")
            }
            completion(success, text)
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

    /// Find textbook by subject name (fuzzy matching)
    func findTextbook(subject: String) -> String? {
        let textbooks = listTextbooks()
        let subjectLower = subject.lowercased()

        // Exact match first
        if let exact = textbooks.first(where: { $0.lowercased().contains(subjectLower) }) {
            return exact
        }

        // Try partial matches
        let keywords = ["физика", "алгебра", "геометрия", "история", "биология", "химия", "русский", "литература", "английский"]
        for keyword in keywords {
            if subjectLower.contains(keyword) {
                if let match = textbooks.first(where: { $0.lowercased().contains(keyword) }) {
                    return match
                }
            }
        }

        return nil
    }
}
