import Foundation

struct SearchItem: Identifiable {
    let id = UUID()
    let title: String
    var image: String
    let href: String
}
