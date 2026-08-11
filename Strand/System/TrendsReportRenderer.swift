import SwiftUI
import StrandDesign
import Foundation

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// MARK: - Trends Report Renderer (#436)
//
// Renders a `TrendsReportPage` (a plain SwiftUI view) to a single-page PDF entirely
// on-device, then hands the file to the shared `FileExport` so the user saves it to
// Files / shares it via the system share sheet. No network, no temp account — the PDF
// is written to the app's temporary directory and offered through the OS.
//
// We use SwiftUI's `ImageRenderer` (macOS 13+ / iOS 16+), which exposes a `render`
// closure giving us the rendered size + a CGContext callback. Drawing into a
// `CGContext` created by `CGContext(consumer:mediaBox:…)` (PDF data consumer) gives a
// crisp VECTOR PDF on BOTH platforms from one code path — no UIGraphicsPDFRenderer /
// NSPrintOperation divergence.

enum TrendsReportRenderer {

    /// Render `page` to a one-page PDF in the temp directory and present the share sheet
    /// / save panel via `FileExport`. Must run on the main actor (ImageRenderer is
    /// main-actor bound and touches the view tree).
    @MainActor
    static func exportPDF<Page: View>(page: Page, suggestedName: String) {
        guard let url = makePDF(page: page, fileName: suggestedName) else { return }
        // FileExport handles both platforms: NSSavePanel on macOS, the share sheet on iOS.
        // The temp PDF is the caller's to clean up; FileExport.exportFile leaves caller
        // files in place, so we drop a best-effort cleanup after a delay on iOS isn't
        // needed — the temp dir is reclaimed by the OS, and re-exports overwrite by name.
        FileExport.exportFile(at: url, suggestedName: suggestedName)
    }

    /// Render `page` to a single-page PDF file and return its URL (nil on failure).
    @MainActor
    static func makePDF<Page: View>(page: Page, fileName: String) -> URL? {
        let renderer = ImageRenderer(content: page)
        // Match the on-screen scale so text/line metrics are crisp; 2x is plenty for a
        // print-grade sheet and keeps the file small.
        renderer.scale = 2.0

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        var didRender = false

        renderer.render { size, renderInContext in
            // The PDF media box is the view's logical (unscaled) size — a portrait page.
            var mediaBox = CGRect(origin: .zero, size: size)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let pdf = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
                return
            }
            pdf.beginPDFPage(nil)
            // Paint the page background colour first so the PDF isn't transparent where
            // the view's own background doesn't fully cover (PDF has no default fill).
            pdf.setFillColor(Self.pageBackgroundCGColor)
            pdf.fill(mediaBox)
            renderInContext(pdf)
            pdf.endPDFPage()
            pdf.closePDF()
            didRender = true
        }

        return didRender ? url : nil
    }

    /// Render `page` to a PNG in the temp directory and present the share sheet / save panel via
    /// `FileExport` — the image sibling of `exportPDF`, used for the shareable weekly recap card.
    @MainActor
    static func exportPNG<Page: View>(page: Page, suggestedName: String) {
        guard let url = makePNG(page: page, fileName: suggestedName) else { return }
        FileExport.exportFile(at: url, suggestedName: suggestedName)
    }

    /// Render `page` to a PNG file and return its URL (nil on failure). The page must carry its own
    /// opaque background (`ImageRenderer.uiImage`/`nsImage` composites the view tree as-is), so callers
    /// wrap the content in a `surfaceBase` background — no explicit media-box fill like the PDF path.
    @MainActor
    static func makePNG<Page: View>(page: Page, fileName: String) -> URL? {
        let renderer = ImageRenderer(content: page)
        renderer.scale = 2.0
        #if canImport(UIKit)
        guard let data = renderer.uiImage?.pngData() else { return nil }
        #elseif canImport(AppKit)
        guard let img = renderer.nsImage, let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return nil }
        #else
        return nil
        #endif
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    /// The report page's deep-navy canvas colour as a CGColor, so the PDF's media box is
    /// filled before the view draws (PDF pages start transparent). Pulled from the same
    /// `StrandPalette.surfaceBase` token the page uses, so there's no colour drift.
    private static var pageBackgroundCGColor: CGColor {
        #if canImport(AppKit)
        return NSColor(StrandPalette.surfaceBase).cgColor
        #elseif canImport(UIKit)
        return UIColor(StrandPalette.surfaceBase).cgColor
        #else
        return CGColor(gray: 0, alpha: 1)
        #endif
    }
}
