import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

// Content-Length only, bounded requests, no ambiguous duplicate headers or chunked bodies.
struct HTTPParser {
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws {
        guard buffer.count + bytes.count <= 65536 else { throw WebError.tooLarge }
        buffer.append(bytes)
    }
    mutating func next() throws -> HTTPRequest? {
        guard let boundary = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 8192 { throw WebError.tooLarge }
            return nil
        }
        guard boundary.lowerBound <= 8192,
              let head = String(data: buffer[..<boundary.lowerBound], encoding: .utf8) else { throw WebError.badRequest }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(String(first[0])),
              first[1].hasPrefix("/"), !first[1].hasPrefix("//") else { throw WebError.badRequest }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else { throw WebError.badRequest }
            let key = String(line[..<colon]).lowercased()
            guard !key.isEmpty, key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), headers[key] == nil else { throw WebError.badRequest }
            headers[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard headers["host"] != nil, headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw WebError.badRequest }
        let rawLength = headers["content-length"] ?? "0"
        guard !rawLength.isEmpty, rawLength.allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int(rawLength), length <= 32768 else { throw WebError.tooLarge }
        if first[0] == "GET" && length != 0 { throw WebError.badRequest }
        let end = boundary.upperBound + length
        guard buffer.count >= end else { return nil }
        let body = Data(buffer[boundary.upperBound..<end])
        buffer = Data(buffer.dropFirst(end))
        return HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
    }
}

struct HTTPResponse {
    var code = 200
    var contentType = "application/json; charset=utf-8"
    var body: Data
    init(_ code: Int = 200, json: [String: Any]) {
        self.code = code
        body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
    }
    init(data: Data, contentType: String) { body = data; self.contentType = contentType }
    var data: Data {
        let reason = code == 200 ? "OK" : "Error"
        let headers = "HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(body.count)\r\nContent-Type: \(contentType)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\nConnection: keep-alive\r\n\r\n"
        return Data(headers.utf8) + body
    }
}
