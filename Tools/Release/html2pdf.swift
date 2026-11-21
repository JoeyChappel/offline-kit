// Renders an HTML file to a paginated US Letter PDF with WebKit.
// usage: swift html2pdf.swift input.html output.pdf
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 3 else { print("usage: html2pdf input.html output.pdf"); exit(2) }
let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])

final class Renderer: NSObject, WKNavigationDelegate {
    let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 816, height: 1056))
    func run() {
        web.navigationDelegate = self
        web.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)          // US Letter, points
        info.topMargin = 0; info.bottomMargin = 0; info.leftMargin = 0; info.rightMargin = 0  // CSS @page sets margins
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        let op = webView.printOperation(with: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        op.view?.frame = NSRect(x: 0, y: 0, width: 612, height: 792)
        op.runModal(for: NSWindow(), delegate: self, didRun: #selector(done), contextInfo: nil)
    }
    @objc func done() { print("wrote \(output.path)"); exit(0) }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer()
renderer.run()
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { print("timed out"); exit(1) }
app.run()
