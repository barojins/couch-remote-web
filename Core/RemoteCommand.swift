import Foundation

enum RemoteKey: String, CaseIterable, Codable {
    case returnKey, backspace, escape, space, left, right, up, down, tab
    case volumeDown, mute, volumeUp
}
enum RemoteCommand: Equatable {
    case move(Int16, Int16), scroll(Int16, Int16)
    case click, doubleClick, rightClick, text(String), key(RemoteKey)
}
struct WebCommand: Decodable {
    var type: String
    var x: Int?
    var y: Int?
    var text: String?
    var key: RemoteKey?

    func validated() throws -> [RemoteCommand] {
        switch type {
        case "move", "scroll":
            guard let x, let y, abs(Double(x)) <= 8192, abs(Double(y)) <= 8192 else { throw WebError.badRequest }
            return [type == "move" ? .move(Int16(x), Int16(y)) : .scroll(Int16(x), Int16(y))]
        case "click": return [.click]
        case "doubleClick": return [.doubleClick]
        case "rightClick": return [.rightClick]
        case "key":
            guard let key else { throw WebError.badRequest }
            return [.key(key)]
        case "text":
            guard let text, text.utf8.count <= 4096 else { throw WebError.badRequest }
            var commands: [RemoteCommand] = [], chunk = ""
            for scalar in text.unicodeScalars {
                if scalar.properties.generalCategory == .control {
                    if !chunk.isEmpty { commands.append(.text(chunk)); chunk = "" }
                    switch scalar.value {
                    case 10: commands.append(.key(.returnKey))
                    case 9: commands.append(.key(.tab))
                    default: throw WebError.badRequest
                    }
                } else { chunk.unicodeScalars.append(scalar) }
            }
            if !chunk.isEmpty { commands.append(.text(chunk)) }
            return commands
        default: throw WebError.badRequest
        }
    }
}
enum WebError: Error { case badRequest, tooLarge }
