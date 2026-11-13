import Foundation

/// `POST /v1/uploads/presign` response, with `uploadURL` already rewritten for devices.
public struct PresignedUpload: Sendable, Equatable {
    public var uploadURL: URL
    /// Short-lived read URL. Never persist it; persist `objectKey`.
    public var fileURL: URL
    public var objectKey: String
    /// Non-empty for S3/MinIO presigned POST (multipart); empty for presigned PUT (OSS / local).
    public var fields: [String: String]
}

public enum UploadError: Error, Sendable, Equatable {
    case invalidPresign
    case uploadFailed(status: Int)
}

/// Presign → upload. The backend hands out an in-cluster host (`minio:9000`) that a
/// device can't resolve; it is rewritten to the public `file_url` host. Safe because
/// a presigned POST signs the form policy, not the host.
public struct PresignedUploader: Sendable {
    public static let maxContentLength = 10 * 1024 * 1024
    static let internalHosts: Set<String> = ["minio", "localhost", "127.0.0.1", "0.0.0.0"]

    private let api: APIClient
    private let transport: any HTTPTransport

    public init(api: APIClient, transport: any HTTPTransport = URLSessionTransport()) {
        self.api = api
        self.transport = transport
    }

    /// Uploads JPEG/PNG bytes and returns the presign (use `objectKey` / `fileURL`).
    public func upload(_ data: Data, fileName: String, contentType: String) async throws -> PresignedUpload {
        let endpoint = try Endpoint<Wire.PresignUploadResponse>(
            .post,
            "/v1/uploads/presign",
            json: Wire.PresignUploadRequest(
                fileName: fileName, contentType: contentType, maxContentLength: Self.maxContentLength
            )
        )
        let presign = try Self.makeUpload(from: await api.send(endpoint))

        var request = URLRequest(url: presign.uploadURL, timeoutInterval: 60)
        if presign.fields.isEmpty {
            request.httpMethod = "PUT"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        } else {
            let boundary = "aidrobe-\(UUID().uuidString)"
            request.httpMethod = "POST"
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.multipartBody(
                fields: presign.fields, file: data, fileName: fileName, contentType: contentType, boundary: boundary
            )
        }
        let (_, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw UploadError.uploadFailed(status: response.statusCode)
        }
        return presign
    }

    static func makeUpload(from response: Wire.PresignUploadResponse) throws -> PresignedUpload {
        guard let upload = URL(string: response.uploadUrl), let file = URL(string: response.fileUrl) else {
            throw UploadError.invalidPresign
        }
        return PresignedUpload(
            uploadURL: normalize(uploadURL: upload, publicURL: file),
            fileURL: file,
            objectKey: response.objectKey,
            fields: response.fields?.additionalProperties ?? [:]
        )
    }

    static func normalize(uploadURL: URL, publicURL: URL) -> URL {
        guard let host = uploadURL.host(), internalHosts.contains(host),
              var components = URLComponents(url: uploadURL, resolvingAgainstBaseURL: false) else {
            return uploadURL
        }
        components.scheme = publicURL.scheme
        components.host = publicURL.host()
        if let port = publicURL.port { components.port = port }
        return components.url ?? uploadURL
    }

    /// S3 presigned POST: policy fields first, `file` last.
    static func multipartBody(
        fields: [String: String],
        file: Data,
        fileName: String,
        contentType: String,
        boundary: String
    ) -> Data {
        var body = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}
