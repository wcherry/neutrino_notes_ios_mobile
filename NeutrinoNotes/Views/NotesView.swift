import SwiftUI

struct NotesView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Notes")
                .font(.largeTitle)
            Spacer()
        }
        .navigationTitle("Notes")
    }
}

#Preview {
    NavigationStack {
        NotesView()
    }
}
