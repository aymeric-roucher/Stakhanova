import SwiftUI

struct SettingsView: View {
    @StateObject private var storageService = StorageService()
    @StateObject private var analyticsService = AnalyticsService()

    @State private var bucketName: String = ""
    @State private var serviceAccountJSON: String = ""
    @State private var apiKey: String = ""
    @State private var selectedProvider: LLMProvider = .anthropic

    var body: some View {
        TabView {
            // Google Cloud Storage settings
            Form {
                Section(header: Text("Google Cloud Storage")) {
                    TextField("Bucket Name", text: $bucketName)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading) {
                        Text("Service Account JSON")
                            .font(.headline)
                        TextEditor(text: $serviceAccountJSON)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 200)
                            .border(Color.gray.opacity(0.2))
                    }

                    Button("Save GCS Settings") {
                        storageService.bucketName = bucketName
                        storageService.serviceAccountJSON = serviceAccountJSON
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section(header: Text("Instructions")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Create a Google Cloud Storage bucket")
                        Text("2. Create a service account with Storage Admin role")
                        Text("3. Download the service account JSON key")
                        Text("4. Paste the entire JSON content above")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .tabItem {
                Label("Storage", systemImage: "externaldrive.fill")
            }

            // LLM API settings
            Form {
                Section(header: Text("LLM Provider")) {
                    Picker("Provider", selection: $selectedProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)

                    SecureField("API Key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)

                    Button("Save API Settings") {
                        analyticsService.apiProvider = selectedProvider
                        analyticsService.apiKey = apiKey
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section(header: Text("Current Provider")) {
                    switch selectedProvider {
                    case .anthropic:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Using Claude 3.5 Sonnet")
                            Text("Get your API key at: console.anthropic.com")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    case .openai:
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Using GPT-4 Turbo")
                            Text("Get your API key at: platform.openai.com")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .padding()
            .tabItem {
                Label("Analytics", systemImage: "brain.head.profile")
            }

            // About
            Form {
                Section(header: Text("About Stakhanova")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Stakhanova captures your click interactions and provides AI-powered analytics about your productivity and app usage patterns.")

                        Text("Required Permissions:")
                            .font(.headline)
                            .padding(.top)

                        VStack(alignment: .leading, spacing: 4) {
                            Label("Screen Recording", systemImage: "checkmark.circle.fill")
                            Label("Accessibility", systemImage: "checkmark.circle.fill")
                        }
                        .foregroundColor(.green)

                        Button("Open System Preferences") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                        .padding(.top)
                    }
                }
            }
            .padding()
            .tabItem {
                Label("About", systemImage: "info.circle")
            }
        }
        .frame(width: 600, height: 500)
        .onAppear {
            loadSettings()
        }
    }

    private func loadSettings() {
        bucketName = storageService.bucketName ?? ""
        serviceAccountJSON = storageService.serviceAccountJSON ?? ""
        apiKey = analyticsService.apiKey ?? ""
        selectedProvider = analyticsService.apiProvider
    }
}

#Preview {
    SettingsView()
}
