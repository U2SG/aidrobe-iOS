import Foundation

extension Endpoints {
    public static func stylingExperiences(outfitID: String) -> Endpoint<Wire.StylingExperienceListResponse> {
        Endpoint(.get, "/v1/styling-experiences", query: [
            URLQueryItem(name: "outfit_id", value: outfitID),
            URLQueryItem(name: "limit", value: "100"),
        ])
    }

    public static func recordStylingExperience(_ body: Wire.StylingExperienceRequest) throws -> Endpoint<Wire.StylingExperienceResponse> {
        try Endpoint(.post, "/v1/styling-experiences", json: body)
    }

    public static func removeStylingExperience(_ id: String) -> Endpoint<Wire.StylingExperienceDeleteResponse> {
        Endpoint(.delete, "/v1/styling-experiences/\(id)")
    }
}
