// Decode QR codes in PNG files with macOS Vision; prints one JSON line per file: {"file":..., "text":...}.
import Foundation
import Vision
for path in CommandLine.arguments.dropFirst() {
    let req = VNDetectBarcodesRequest()
    req.symbologies = [.qr]
    let handler = VNImageRequestHandler(url: URL(fileURLWithPath: path))
    var text: String? = nil
    do { try handler.perform([req]); text = (req.results?.first)?.payloadStringValue } catch {}
    let obj: [String: Any] = ["file": path, "text": text ?? NSNull()]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    print(String(data: data, encoding: .utf8)!)
}
