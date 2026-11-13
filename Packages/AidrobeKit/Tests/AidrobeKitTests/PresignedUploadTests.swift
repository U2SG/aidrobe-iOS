import Foundation
import Testing
@testable import AidrobeKit

@Suite struct PresignedUploadTests {
    @Test(arguments: ["minio", "localhost", "127.0.0.1", "0.0.0.0"])
    func rewritesInternalHosts(host: String) throws {
        let upload = URL(string: "http://\(host):9000/bucket?x=1")!
        let file = URL(string: "http://100.89.226.13:9100/bucket/users/a.jpg")!
        let result = PresignedUploader.normalize(uploadURL: upload, publicURL: file)
        #expect(result.absoluteString == "http://100.89.226.13:9100/bucket?x=1")
    }

    @Test func keepsPublicHosts() {
        let upload = URL(string: "https://aidrobe.oss-cn-hangzhou.aliyuncs.com/key?sig=1")!
        let file = URL(string: "https://cdn.aidrobe.app/key")!
        #expect(PresignedUploader.normalize(uploadURL: upload, publicURL: file) == upload)
    }

    @Test func keepsPortWhenPublicURLHasNone() {
        let upload = URL(string: "http://minio:9000/bucket")!
        let file = URL(string: "https://files.aidrobe.app/bucket/a.jpg")!
        #expect(PresignedUploader.normalize(uploadURL: upload, publicURL: file).absoluteString == "https://files.aidrobe.app:9000/bucket")
    }

    @Test func multipartPutsFieldsBeforeFile() throws {
        let body = PresignedUploader.multipartBody(
            fields: ["key": "users/a.jpg", "policy": "p"],
            file: Data("IMG".utf8),
            fileName: "a.jpg",
            contentType: "image/jpeg",
            boundary: "B"
        )
        let text = try #require(String(data: body, encoding: .utf8))
        let keyIndex = try #require(text.range(of: "name=\"key\"")).lowerBound
        let fileIndex = try #require(text.range(of: "name=\"file\"")).lowerBound
        #expect(keyIndex < fileIndex)
        #expect(text.hasSuffix("\r\n--B--\r\n"))
    }

    @Test func uploadUsesPutWhenNoFields() async throws {
        let presignBody = #"{"code":0,"message":"","data":{"upload_url":"http://localhost:9000/b/k","file_url":"http://10.0.0.2:9000/b/k","object_key":"users/k.jpg"}}"#
        let apiTransport = StubTransport { _ in (200, presignBody) }
        let api = APIClient(
            environment: AppEnvironment(stage: .development, apiBaseURL: URL(string: "http://api.test")!),
            tokens: TokenStore(store: InMemorySecureStore()),
            transport: apiTransport
        )
        let storage = StubTransport { _ in (200, "") }
        let result = try await PresignedUploader(api: api, transport: storage)
            .upload(Data("IMG".utf8), fileName: "k.jpg", contentType: "image/jpeg")
        #expect(result.objectKey == "users/k.jpg")
        let request = try #require(storage.requests.first)
        #expect(request.httpMethod == "PUT")
        #expect(request.url?.absoluteString == "http://10.0.0.2:9000/b/k")
    }
}
