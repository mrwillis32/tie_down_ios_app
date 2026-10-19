import SwiftUI

struct MoreView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var auth: AuthService

    var body: some View {
        NavigationStack {
            List {
                if let user = auth.session?.user {
                    Section {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(Color.accentColor.opacity(0.15))
                                .frame(width: 44, height: 44)
                                .overlay(
                                    Text(String(user.displayName.prefix(1)).uppercased())
                                        .font(.headline)
                                        .foregroundStyle(Color.accentColor)
                                )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.displayName).font(.headline)
                                Text(user.organizationName ?? user.email)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section {
                    ForEach(model.moreItems) { item in
                        NavigationLink {
                            WebScreen(model: model.screen(for: item), title: item.title)
                        } label: {
                            Label(item.title, systemImage: item.systemImage)
                        }
                    }
                }

                Section {
                    NavigationLink {
                        AppSettingsView()
                    } label: {
                        Label("App Settings", systemImage: "iphone.gen3")
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await model.signOut() }
                    } label: {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("More")
        }
    }
}
