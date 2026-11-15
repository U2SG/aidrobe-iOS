import Foundation

extension Endpoints {
    public static func inspirations(limit: Int = 30, offset: Int = 0) -> Endpoint<Wire.InspirationListResponse> {
        Endpoint(.get, "/v1/style/inspirations", query: [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ])
    }

    public static func addInspiration(imageURL: String? = nil, sourceURL: String? = nil)
        throws -> Endpoint<Wire.InspirationResponse> {
        try Endpoint(.post, "/v1/style/inspirations", json: Wire.AddInspirationRequest(
            imageUrl: imageURL, sourceUrl: sourceURL
        ))
    }

    public static func addStyleMagazine(url: String) throws -> Endpoint<Wire.PdfStyleSourceResponse> {
        try Endpoint(.post, "/v1/style/sources", json: Wire.PdfStyleSourceRequest(fileUrl: url))
    }

    public static func removeInspiration(_ id: String) -> Endpoint<EmptyResponse> {
        Endpoint(.delete, "/v1/style/inspirations/\(id)")
    }

    public static func styleTags() -> Endpoint<Wire.StyleTagsResponse> {
        Endpoint(.get, "/v1/style/tags")
    }

    public static func updateStyleTags(_ tags: [String]) throws -> Endpoint<EmptyResponse> {
        try Endpoint(.patch, "/v1/style/tags", json: Wire.UpdateStyleTagsRequest(tags: tags))
    }
}
