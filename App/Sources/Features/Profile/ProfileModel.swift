import AidrobeKit
import CoreLocation
import Foundation
import MapKit

@MainActor
@Observable
final class ProfileModel {
    private(set) var settings: Wire.UserSettingsResponse?
    private(set) var history: [Wire.OutfitHistoryEntry] = []
    private(set) var historyTotal = 0
    private(set) var isLocating = false
    var notice: String?

    private let api: APIClient

    init(api: APIClient) {
        self.api = api
    }

    /// Days this month with a recorded outfit.
    var daysThisMonth: Int {
        let now = Calendar.current.dateComponents([.year, .month], from: .now)
        let month = String(format: "%04d-%02d", now.year ?? 0, now.month ?? 0)
        return Set(history.map(\.wornDate).filter { $0.hasPrefix(month) }).count
    }

    func load() async {
        async let settings = try? api.send(Endpoints.settings())
        async let history = try? api.send(Endpoints.outfitHistory())
        if let settings = await settings { self.settings = settings }
        if let history = await history {
            self.history = history.items
            historyTotal = history.total
        }
    }

    var departure: Date {
        let time = settings?.departureTime.flatMap(SettingsFormat.hourMinute) ?? (8, 0)
        return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: .now) ?? .now
    }

    func setDeparture(_ date: Date) async {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        await save(.init(departureTime: SettingsFormat.departureTime(hour: parts.hour ?? 8, minute: parts.minute ?? 0)))
    }

    func setCommute(_ exposure: Wire.UpdateUserSettingsRequest.CommuteExposurePayload) async {
        await save(.init(commuteExposure: exposure))
    }

    /// Reads the device location once and stores it as the weather location.
    /// Returns the place name to show, if one could be resolved.
    func useCurrentLocation() async -> String? {
        let generation = AccountLocalData.generation
        isLocating = true
        defer { isLocating = false }
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDenied {
                    notice = "没有定位权限，可以在系统设置里打开"
                    return nil
                }
                guard generation == AccountLocalData.generation else { return nil }
                guard let location = update.location else { continue }
                await save(.init(location: SettingsFormat.location(
                    latitude: location.coordinate.latitude, longitude: location.coordinate.longitude
                )))
                let place = try? await MKReverseGeocodingRequest(location: location)?.mapItems.first
                return place?.addressRepresentations?.cityName ?? "当前位置"
            }
        } catch {
            notice = "没能拿到位置，稍后再试"
        }
        return nil
    }

    private func save(_ changes: Wire.UpdateUserSettingsRequest) async {
        do {
            settings = try await api.send(Endpoints.updateSettings(changes))
        } catch {
            notice = userMessage(for: error)
        }
    }
}
