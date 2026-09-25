import SwiftUI

extension MediaKind {
    /// The pill label on Simkl's Home and Search.
    var simklKindTitle: String {
        switch self {
        case .anime: return "Anime"
        case .manga: return "Manga"
        case .tv:    return "Shows"
        case .movie: return "Movies"
        }
    }
}

/// Anime / Shows / Movies, on Simkl's Home and Search.
struct SimklKindPicker: View {
    @Binding var kind: MediaKind

    var body: some View {
        Picker("Kind", selection: $kind) {
            ForEach(MediaKind.simklKinds, id: \.self) { kind in
                Text(kind.simklKindTitle).tag(kind)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
    }
}
