import CoreFoundation
import Foundation

enum SubtitleTextDecoder {
    static func decode(_ data: Data) -> String? {
        let chinese = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let traditionalChinese = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)))
        if let text = String(data: data, encoding: .utf8) { return text }
        let prefix = data.prefix(128)
        let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
        let hasUTF16Zeros = prefix.filter { $0 == 0 }.count > prefix.count / 8
        if hasUTF16BOM || hasUTF16Zeros,
           let text = String(data: data, encoding: .utf16) { return text }
        for encoding in [chinese, traditionalChinese, .windowsCP1252] {
            if let text = String(data: data, encoding: encoding) { return text }
        }
        return nil
    }
}
