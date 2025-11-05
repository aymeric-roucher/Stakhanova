import Foundation

class StorageService: ObservableObject {
    private let userDefaults = UserDefaults.standard
    private let bucketNameKey = "GCSBucketName"
    private let serviceAccountKey = "GCSServiceAccount"

    var bucketName: String? {
        get { userDefaults.string(forKey: bucketNameKey) }
        set { userDefaults.set(newValue, forKey: bucketNameKey) }
    }

    var serviceAccountJSON: String? {
        get { userDefaults.string(forKey: serviceAccountKey) }
        set { userDefaults.set(newValue, forKey: serviceAccountKey) }
    }

    /// Upload a click event to Google Cloud Storage
    func uploadClickEvent(_ event: ClickEvent) async throws {
        guard let bucketName = bucketName,
              let _ = serviceAccountJSON else {
            throw StorageError.missingConfiguration
        }

        // Upload metadata
        try await uploadToGCS(
            bucketName: bucketName,
            objectName: "\(event.id.uuidString)/metadata.json",
            data: try encodeEventMetadata(event),
            contentType: "application/json"
        )

        // Upload screenshots
        if let beforeData = event.screenshotBeforeClick {
            try await uploadToGCS(
                bucketName: bucketName,
                objectName: "\(event.id.uuidString)/screenshot_before.png",
                data: beforeData,
                contentType: "image/png"
            )
        }

        if let afterData = event.screenshotAfterClick {
            try await uploadToGCS(
                bucketName: bucketName,
                objectName: "\(event.id.uuidString)/screenshot_after.png",
                data: afterData,
                contentType: "image/png"
            )
        }
    }

    private func encodeEventMetadata(_ event: ClickEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        return try encoder.encode(event)
    }

    private func uploadToGCS(bucketName: String, objectName: String, data: Data, contentType: String) async throws {
        // Get access token from service account
        let accessToken = try await getAccessToken()

        // Construct upload URL
        let uploadURL = URL(string: "https://storage.googleapis.com/upload/storage/v1/b/\(bucketName)/o?uploadType=media&name=\(objectName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? objectName)")!

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw StorageError.uploadFailed
        }
    }

    /// Get OAuth2 access token from service account JSON
    private func getAccessToken() async throws -> String {
        guard let serviceAccountJSON = serviceAccountJSON,
              let jsonData = serviceAccountJSON.data(using: .utf8),
              let serviceAccount = try? JSONDecoder().decode(ServiceAccountCredentials.self, from: jsonData) else {
            throw StorageError.invalidCredentials
        }

        // Create JWT
        let jwt = try createJWT(serviceAccount: serviceAccount)

        // Exchange JWT for access token
        let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw StorageError.authenticationFailed
        }

        let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
        return tokenResponse.access_token
    }

    private func createJWT(serviceAccount: ServiceAccountCredentials) throws -> String {
        // For production, use a proper JWT library like SwiftJWT
        // This is a simplified placeholder
        // TODO: Implement proper JWT signing with RS256
        throw StorageError.notImplemented
    }

    /// Fetch all click events from Google Cloud Storage
    func fetchAllClickEvents() async throws -> [ClickEvent] {
        guard let bucketName = bucketName else {
            throw StorageError.missingConfiguration
        }

        let accessToken = try await getAccessToken()

        // List all objects in bucket
        let listURL = URL(string: "https://storage.googleapis.com/storage/v1/b/\(bucketName)/o")!
        var request = URLRequest(url: listURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)
        let listResponse = try JSONDecoder().decode(GCSListResponse.self, from: data)

        // Download and parse each metadata.json file
        var events: [ClickEvent] = []
        for item in listResponse.items where item.name.hasSuffix("metadata.json") {
            if let event = try? await fetchClickEvent(objectName: item.name, accessToken: accessToken) {
                events.append(event)
            }
        }

        return events
    }

    private func fetchClickEvent(objectName: String, accessToken: String) async throws -> ClickEvent {
        guard let bucketName = bucketName else {
            throw StorageError.missingConfiguration
        }

        let downloadURL = URL(string: "https://storage.googleapis.com/storage/v1/b/\(bucketName)/o/\(objectName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? objectName)?alt=media")!
        var request = URLRequest(url: downloadURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, _) = try await URLSession.shared.data(for: request)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ClickEvent.self, from: data)
    }
}

// MARK: - Models

struct ServiceAccountCredentials: Codable {
    let type: String
    let project_id: String
    let private_key_id: String
    let private_key: String
    let client_email: String
    let client_id: String
    let auth_uri: String
    let token_uri: String
}

struct TokenResponse: Codable {
    let access_token: String
    let expires_in: Int
    let token_type: String
}

struct GCSListResponse: Codable {
    let items: [GCSObject]
}

struct GCSObject: Codable {
    let name: String
    let size: String?
}

enum StorageError: Error {
    case missingConfiguration
    case invalidCredentials
    case uploadFailed
    case authenticationFailed
    case notImplemented
}
