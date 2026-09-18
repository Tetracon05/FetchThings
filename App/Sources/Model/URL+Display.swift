import Foundation

extension URL {
    /// The file path as people write it: `~/Downloads`, not `/Users/name/Downloads`.
    var displayPath: String {
        (path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}
