import Foundation

/// Streams `<trkpt>` elements out of a GPX file.
final class GPXParser: NSObject, XMLParserDelegate {
    struct Point {
        var lat: Double
        var lon: Double
        var ele: Double?
        var time: Date?
    }

    private var points: [Point] = []
    private var current: Point?
    private var text = ""

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let iso = ISO8601DateFormatter()

    static func points(_ data: Data) -> [Point] {
        let delegate = GPXParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.points
    }

    static func date(_ string: String) -> Date? {
        iso.date(from: string) ?? isoFractional.date(from: string)
    }

    func parser(
        _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
        qualifiedName: String?, attributes: [String: String] = [:]
    ) {
        text = ""
        if name == "trkpt", let lat = attributes["lat"].flatMap(Double.init),
           let lon = attributes["lon"].flatMap(Double.init) {
            current = Point(lat: lat, lon: lon)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(
        _ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
        qualifiedName: String?
    ) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "ele": current?.ele = Double(value)
        case "time": current?.time = Self.date(value)
        case "trkpt":
            if let current { points.append(current) }
            current = nil
        default: break
        }
        text = ""
    }
}
