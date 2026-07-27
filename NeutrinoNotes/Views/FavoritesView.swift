import SwiftUI

struct FavoritesView: View {
    var body: some View {
        VStack {
            Spacer()
            Text("Favorites")
                .font(.largeTitle)
            Spacer()
        }
        .navigationTitle("Favorites")
    }
}

#Preview {
    NavigationStack {
        FavoritesView()
    }
}
