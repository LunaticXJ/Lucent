import Foundation

enum DLNAClient {
    struct Device: Sendable {
        let name: String
        let descriptionURL: URL
        let controlURL: URL
        let serviceType: String
    }

    struct Video: Sendable {
        let title: String
        let url: URL
    }

    static func connect(descriptionURL: URL) async throws -> Device {
        guard ["http", "https"].contains(descriptionURL.scheme?.lowercased() ?? "") else {
            throw DLNAError.invalidAddress
        }
        var request = URLRequest(url: descriptionURL)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else {
            throw DLNAError.invalidResponse
        }
        let parser = DeviceDescriptionParser(data: data)
        guard let description = try parser.parse(),
              let controlURL = URL(string: description.controlURL, relativeTo: descriptionURL)?.absoluteURL,
              controlURL.host == descriptionURL.host else { throw DLNAError.noContentDirectory }
        return Device(name: description.name, descriptionURL: descriptionURL,
                      controlURL: controlURL, serviceType: description.serviceType)
    }

    static func scan(device: Device) async throws -> [Video] {
        var queue = ["0"]
        var visited = Set<String>()
        var urls = Set<URL>()
        var videos: [Video] = []
        while !queue.isEmpty {
            try Task.checkCancellation()
            let container = queue.removeFirst()
            guard visited.insert(container).inserted else { continue }
            var start = 0
            while true {
                let response = try await browse(device: device, objectID: container, start: start)
                let entries = try DIDLParser(data: Data(response.result.utf8)).parse()
                for entry in entries {
                    if entry.isContainer {
                        queue.append(entry.id)
                    } else if let url = entry.url,
                              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                              urls.insert(url).inserted {
                        videos.append(Video(title: entry.title, url: url))
                    }
                }
                start += response.numberReturned
                if start >= response.totalMatches || response.numberReturned == 0 { break }
                if start > 50_000 { throw DLNAError.tooManyFiles }
            }
            if queue.count + visited.count > 50_000 || videos.count > 50_000 {
                throw DLNAError.tooManyFiles
            }
        }
        return videos
    }

    private static func browse(device: Device, objectID: String, start: Int) async throws -> BrowseResponse {
        let escapedID = objectID.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
        <s:Body><u:Browse xmlns:u="\(device.serviceType)"><ObjectID>\(escapedID)</ObjectID><BrowseFlag>BrowseDirectChildren</BrowseFlag><Filter>*</Filter><StartingIndex>\(start)</StartingIndex><RequestedCount>200</RequestedCount><SortCriteria></SortCriteria></u:Browse></s:Body></s:Envelope>
        """
        var request = URLRequest(url: device.controlURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(device.serviceType)#Browse\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = Data(xml.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else {
            throw DLNAError.invalidResponse
        }
        return try BrowseResponseParser(data: data).parse()
    }
}

private struct BrowseResponse { let result: String; let numberReturned: Int; let totalMatches: Int }

private final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    struct Description { let name: String; let controlURL: String; let serviceType: String }
    private let parser: XMLParser
    private var current = ""
    private var name = ""
    private var serviceType = ""
    private var controlURL = ""
    private var inService = false
    private var chosen: Description?

    init(data: Data) { parser = XMLParser(data: data); super.init(); parser.delegate = self }
    func parse() throws -> Description? {
        guard parser.parse() else { throw parser.parserError ?? DLNAError.invalidResponse }
        return chosen
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        current = elementName.split(separator: ":").last?.lowercased() ?? ""
        if current == "service" { inService = true; serviceType = ""; controlURL = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch current {
        case "friendlyname": name += string
        case "servicetype" where inService: serviceType += string
        case "controlurl" where inService: controlURL += string
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let element = elementName.split(separator: ":").last?.lowercased() ?? ""
        if element == "service" {
            if chosen == nil, serviceType.contains(":ContentDirectory:") {
                chosen = Description(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                     ? "DLNA" : name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     controlURL: controlURL.trimmingCharacters(in: .whitespacesAndNewlines),
                                     serviceType: serviceType.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            inService = false
        }
        current = ""
    }
}

private final class BrowseResponseParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var field = ""
    private var result = ""
    private var number = ""
    private var total = ""
    init(data: Data) { parser = XMLParser(data: data); super.init(); parser.delegate = self }
    func parse() throws -> BrowseResponse {
        guard parser.parse(), let count = Int(number.trimmingCharacters(in: .whitespacesAndNewlines)),
              let matches = Int(total.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw parser.parserError ?? DLNAError.invalidResponse
        }
        return BrowseResponse(result: result, numberReturned: count, totalMatches: matches)
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        field = elementName.split(separator: ":").last?.lowercased() ?? ""
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        switch field {
        case "result": result += string
        case "numberreturned": number += string
        case "totalmatches": total += string
        default: break
        }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) { field = "" }
}

private final class DIDLParser: NSObject, XMLParserDelegate {
    struct Entry { let id: String; let title: String; let isContainer: Bool; let url: URL? }
    private let parser: XMLParser
    private var entries: [Entry] = []
    private var field = ""
    private var id = ""
    private var title = ""
    private var isContainer = false
    private var resource = ""
    private var selectedResource = ""
    private var resourceIsVideo = false

    init(data: Data) { parser = XMLParser(data: data); super.init(); parser.delegate = self }
    func parse() throws -> [Entry] {
        guard parser.parse() else { throw parser.parserError ?? DLNAError.invalidResponse }
        return entries
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        field = elementName.split(separator: ":").last?.lowercased() ?? ""
        if field == "container" || field == "item" {
            id = attributeDict["id"] ?? ""
            title = ""
            resource = ""
            selectedResource = ""
            isContainer = field == "container"
        }
        if field == "res" {
            resource = ""
            let info = attributeDict["protocolInfo"]?.lowercased() ?? ""
            resourceIsVideo = info.contains(":video/") || info.contains("application/octet-stream")
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if field == "title" { title += string }
        if field == "res" && resourceIsVideo { resource += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let element = elementName.split(separator: ":").last?.lowercased() ?? ""
        if element == "res", resourceIsVideo, selectedResource.isEmpty {
            selectedResource = resource.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if element == "container" || element == "item" {
            if !id.isEmpty { entries.append(Entry(id: id, title: title, isContainer: isContainer,
                                                  url: URL(string: selectedResource))) }
        }
        field = ""
    }
}

private enum DLNAError: LocalizedError {
    case invalidAddress, invalidResponse, noContentDirectory, tooManyFiles
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入有效的 DLNA 设备描述地址。"
        case .invalidResponse: "DLNA 设备返回了无效数据。"
        case .noContentDirectory: "设备不提供 ContentDirectory 服务。"
        case .tooManyFiles: "DLNA 媒体库超过扫描上限。"
        }
    }
}
