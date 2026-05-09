import SwiftUI
import UIKit

@MainActor
final class ChallengeViewModel: ObservableObject {
    @Published private(set) var summary: ChallengeSummary?
    @Published private(set) var logs: [SavingsLogRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var message: String?

    private let repository = ChallengeRepository()

    func load(session: AuthSession) async {
        isLoading = true
        message = nil
        defer { isLoading = false }

        do {
            async let summaryTask = repository.fetchSummary(session: session)
            async let logsTask = repository.fetchRecentLogs(session: session, limit: 20)
            summary = try await summaryTask
            logs = try await logsTask
            if logs.isEmpty {
                message = "아직 기록된 절약 로그가 없어요."
            }
        } catch {
            message = "1억 챌린지 정보를 불러오지 못했어요."
            print("챌린지 조회 실패:", error.localizedDescription)
        }
    }

    func logSaving(_ draft: SavingLogRequest, session: AuthSession) async -> ChallengeSummary? {
        guard draft.savedAmount > 0 else {
            message = "절약액은 1원 이상이어야 해요."
            return nil
        }

        isSaving = true
        message = nil
        defer { isSaving = false }

        do {
            let updatedSummary = try await repository.logSaving(draft, session: session)
            summary = updatedSummary
            logs = try await repository.fetchRecentLogs(session: session, limit: 20)
            message = "이번 방문 절약액이 기록됐어요."
            return updatedSummary
        } catch SupabasePlacesError.requestFailed(_, let body) where body.contains("같은 장소/메뉴") {
            message = "같은 장소/메뉴 절약 기록은 2시간에 한 번만 가능해요."
            return nil
        } catch {
            message = "절약 기록에 실패했어요. 잠시 후 다시 시도해주세요."
            print("절약 기록 실패:", error.localizedDescription)
            return nil
        }
    }

    func cancelSavingLog(_ log: SavingsLogRow, session: AuthSession) async -> ChallengeSummary? {
        isSaving = true
        message = nil
        defer { isSaving = false }

        do {
            let updatedSummary = try await repository.cancelSavingLog(logID: log.id, session: session)
            summary = updatedSummary
            logs = try await repository.fetchRecentLogs(session: session, limit: 20)
            message = "절약 기록을 취소했어요."
            return updatedSummary
        } catch SupabasePlacesError.requestFailed(_, let body) where body.contains("이미 취소") {
            message = "이미 취소된 절약 기록이에요."
            return nil
        } catch {
            message = "절약 기록 취소에 실패했어요. 잠시 후 다시 시도해주세요."
            print("절약 기록 취소 실패:", error.localizedDescription)
            return nil
        }
    }

    func reset() {
        summary = nil
        logs = []
        isLoading = false
        isSaving = false
        message = nil
    }
}

struct ChallengeRepository {
    private let config = SupabaseConfig.current

    func fetchSummary(session: AuthSession) async throws -> ChallengeSummary {
        let rows: [ChallengeSummary] = try await sendRPC(
            path: "get_challenge_summary",
            payload: EmptyRPCPayload(),
            session: session
        )
        guard let summary = rows.first else {
            throw SupabasePlacesError.invalidResponse
        }
        return summary
    }

    func fetchRecentLogs(session: AuthSession, limit: Int) async throws -> [SavingsLogRow] {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/savings_logs"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,user_id,place_id,menu_id,place_name,menu_name,saved_amount,original_price,actual_price,category,source,created_at,cancelled_at,cancelled_reason"),
            URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "cancelled_at", value: "is.null"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]

        guard let url = components?.url else {
            throw SupabasePlacesError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode([SavingsLogRow].self, from: data)
    }

    func logSaving(_ draft: SavingLogRequest, session: AuthSession) async throws -> ChallengeSummary {
        let rows: [ChallengeSummary] = try await sendRPC(
            path: "log_saving",
            payload: draft,
            session: session
        )
        guard let summary = rows.first else {
            throw SupabasePlacesError.invalidResponse
        }
        return summary
    }

    func cancelSavingLog(logID: UUID, session: AuthSession) async throws -> ChallengeSummary {
        let rows: [ChallengeSummary] = try await sendRPC(
            path: "cancel_saving_log",
            payload: CancelSavingLogRequest(logID: logID, reason: "user_cancelled"),
            session: session
        )
        guard let summary = rows.first else {
            throw SupabasePlacesError.invalidResponse
        }
        return summary
    }

    private func sendRPC<T: Encodable, U: Decodable>(
        path: String,
        payload: T,
        session: AuthSession
    ) async throws -> U {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        let url = config.projectURL
            .appendingPathComponent("rest/v1/rpc")
            .appendingPathComponent(path)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(U.self, from: data)
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabasePlacesError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "응답 본문 없음"
            throw SupabasePlacesError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }
    }
}

struct EmptyRPCPayload: Encodable {}

struct GuestSavingLog: Codable, Identifiable {
    let id: UUID
    let placeID: UUID?
    let menuID: UUID?
    let placeName: String
    let menuName: String?
    let savedAmount: Int
    let originalPrice: Int?
    let actualPrice: Int?
    let category: String
    let createdAt: Date
}

enum GuestChallengeStore {
    private static let storageKey = "jjantechmap.guest.savings.logs"
    private static let guestUserID = UUID(uuidString: "99999999-9999-9999-9999-999999999999") ?? UUID()

    static func loadLogs() -> [GuestSavingLog] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return []
        }
        return (try? JSONDecoder().decode([GuestSavingLog].self, from: data)) ?? []
    }

    static func append(_ log: GuestSavingLog) {
        var logs = loadLogs()
        logs.insert(log, at: 0)
        save(Array(logs.prefix(30)))
    }

    static func replace(with logs: [GuestSavingLog]) {
        save(Array(logs.prefix(30)))
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    static func previewLogs() -> [SavingsLogRow] {
        loadLogs().map { log in
            SavingsLogRow(
                id: log.id,
                userID: guestUserID,
                placeID: log.placeID,
                menuID: log.menuID,
                placeName: log.placeName,
                menuName: log.menuName,
                savedAmount: log.savedAmount,
                originalPrice: log.originalPrice,
                actualPrice: log.actualPrice,
                category: log.category,
                source: "guest_preview",
                createdAt: ISO8601DateFormatter().string(from: log.createdAt),
                cancelledAt: nil,
                cancelledReason: nil
            )
        }
    }

    static func previewSummary() -> ChallengeSummary? {
        let logs = loadLogs()
        guard logs.isEmpty == false else { return nil }
        let currentSavings = logs.reduce(0) { $0 + $1.savedAmount }
        let goalAmount = 100_000_000
        let remainingAmount = max(goalAmount - currentSavings, 0)
        let monthlySavings = logs
            .filter { Calendar.current.isDate($0.createdAt, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + $1.savedAmount }

        return ChallengeSummary(
            goalAmount: goalAmount,
            currentSavings: currentSavings,
            remainingAmount: remainingAmount,
            progressRate: Double(currentSavings) / Double(goalAmount) * 100,
            challengeGrade: grade(for: currentSavings),
            monthlySavings: monthlySavings,
            logCount: logs.count
        )
    }

    private static func save(_ logs: [GuestSavingLog]) {
        if let data = try? JSONEncoder().encode(logs) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    private static func grade(for savings: Int) -> String {
        switch savings {
        case 100_000_000...:
            return "1억 달성자"
        case 50_000_000..<100_000_000:
            return "헬조선 생존자"
        case 10_000_000..<50_000_000:
            return "재테크 고수"
        case 1_000_000..<10_000_000:
            return "절약러"
        case 100_000..<1_000_000:
            return "짠돌이"
        default:
            return "흙수저"
        }
    }
}

struct ChallengeSummary: Decodable {
    let goalAmount: Int
    let currentSavings: Int
    let remainingAmount: Int
    let progressRate: Double
    let challengeGrade: String
    let monthlySavings: Int
    let logCount: Int

    enum CodingKeys: String, CodingKey {
        case goalAmount = "goal_amount"
        case currentSavings = "current_savings"
        case remainingAmount = "remaining_amount"
        case progressRate = "progress_rate"
        case challengeGrade = "challenge_grade"
        case monthlySavings = "monthly_savings"
        case logCount = "log_count"
    }

    var progressFraction: Double {
        min(max(Double(currentSavings) / Double(max(goalAmount, 1)), 0), 1)
    }

    var currentSavingsText: String {
        "+\(currentSavings.formatted())원"
    }

    var remainingText: String {
        "\(remainingAmount.formatted())원"
    }

    var monthlySavingsText: String {
        "+\(monthlySavings.formatted())원"
    }

    var progressPercentText: String {
        String(format: "%.2f%%", progressRate)
    }
}

struct SavingsLogRow: Identifiable, Decodable {
    let id: UUID
    let userID: UUID
    let placeID: UUID?
    let menuID: UUID?
    let placeName: String?
    let menuName: String?
    let savedAmount: Int
    let originalPrice: Int?
    let actualPrice: Int?
    let category: String
    let source: String
    let createdAt: String
    let cancelledAt: String?
    let cancelledReason: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case placeID = "place_id"
        case menuID = "menu_id"
        case placeName = "place_name"
        case menuName = "menu_name"
        case savedAmount = "saved_amount"
        case originalPrice = "original_price"
        case actualPrice = "actual_price"
        case category
        case source
        case createdAt = "created_at"
        case cancelledAt = "cancelled_at"
        case cancelledReason = "cancelled_reason"
    }

    var titleText: String {
        let place = placeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let menu = menuName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let place, !place.isEmpty, let menu, !menu.isEmpty {
            return "\(place) · \(menu)"
        }
        if let place, !place.isEmpty {
            return place
        }
        if let menu, !menu.isEmpty {
            return menu
        }
        return "절약 기록"
    }

    var savedAmountText: String {
        "+\(savedAmount.formatted())원"
    }

    var dateText: String {
        String(createdAt.prefix(10))
    }

    var iconText: String {
        switch category {
        case "cafe":
            return "☕"
        case "hair":
            return "✂️"
        case "lodging":
            return "🏨"
        default:
            return "🍱"
        }
    }
}

struct SavingLogRequest: Encodable {
    let placeID: UUID
    let menuID: UUID?
    let placeName: String
    let menuName: String?
    let savedAmount: Int
    let originalPrice: Int?
    let actualPrice: Int?
    let category: String
    let source: String

    enum CodingKeys: String, CodingKey {
        case placeID = "p_place_id"
        case menuID = "p_menu_id"
        case placeName = "p_place_name"
        case menuName = "p_menu_name"
        case savedAmount = "p_saved_amount"
        case originalPrice = "p_original_price"
        case actualPrice = "p_actual_price"
        case category = "p_category"
        case source = "p_source"
    }
}

struct CancelSavingLogRequest: Encodable {
    let logID: UUID
    let reason: String

    enum CodingKeys: String, CodingKey {
        case logID = "p_log_id"
        case reason = "p_reason"
    }
}

struct ChallengeView: View {
    let session: AuthSession
    @EnvironmentObject private var viewModel: ChallengeViewModel
    @State private var isShowingShareCard = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ChallengeHeroCard(summary: viewModel.summary)
                ChallengeGradeCard(summary: viewModel.summary)
                ChallengeMonthCard(
                    summary: viewModel.summary,
                    logs: viewModel.logs,
                    isLoading: viewModel.isLoading,
                    message: viewModel.message,
                    isSaving: viewModel.isSaving,
                    canCancelLogs: true,
                    onCancel: { log in
                        Task {
                            _ = await viewModel.cancelSavingLog(log, session: session)
                        }
                    }
                )

                Button {
                    isShowingShareCard = true
                } label: {
                    Label("내 등급 공유하기", systemImage: "square.and.arrow.up.fill")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Brand.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(viewModel.summary == nil)
            }
            .padding(14)
        }
        .background(Brand.gray50)
        .navigationTitle("1억 챌린지")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.load(session: session)
        }
        .refreshable {
            await viewModel.load(session: session)
        }
        .sheet(isPresented: $isShowingShareCard) {
            if let summary = viewModel.summary {
                GradeShareCardView(summary: summary)
                    .presentationDetents([.medium, .large])
            }
        }
    }
}

struct ChallengePreviewView: View {
    @State private var isShowingShareCard = false
    @State private var guestSummary = GuestChallengeStore.previewSummary()
    @State private var guestLogs = GuestChallengeStore.previewLogs()

    private let sampleSummary = ChallengeSummary(
        goalAmount: 100_000_000,
        currentSavings: 247_300,
        remainingAmount: 99_752_700,
        progressRate: 0.25,
        challengeGrade: "짠돌이",
        monthlySavings: 38_500,
        logCount: 7
    )

    private let sampleLogs = [
        SavingsLogRow(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111") ?? UUID(),
            userID: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
            placeID: nil,
            menuID: nil,
            placeName: "합정 칼국수",
            menuName: "바지락 칼국수",
            savedAmount: 5_000,
            originalPrice: 11_000,
            actualPrice: 6_000,
            category: "food",
            source: "preview",
            createdAt: "2026-05-07T09:00:00+09:00",
            cancelledAt: nil,
            cancelledReason: nil
        ),
        SavingsLogRow(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333") ?? UUID(),
            userID: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
            placeID: nil,
            menuID: nil,
            placeName: "삼천커피",
            menuName: "아메리카노",
            savedAmount: 2_000,
            originalPrice: 5_000,
            actualPrice: 3_000,
            category: "cafe",
            source: "preview",
            createdAt: "2026-05-06T12:30:00+09:00",
            cancelledAt: nil,
            cancelledReason: nil
        ),
        SavingsLogRow(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444") ?? UUID(),
            userID: UUID(uuidString: "22222222-2222-2222-2222-222222222222") ?? UUID(),
            placeID: nil,
            menuID: nil,
            placeName: "동네 백반집",
            menuName: "오늘의 백반",
            savedAmount: 4_500,
            originalPrice: 12_000,
            actualPrice: 7_500,
            category: "food",
            source: "preview",
            createdAt: "2026-05-05T18:10:00+09:00",
            cancelledAt: nil,
            cancelledReason: nil
        )
    ]

    private var visibleSummary: ChallengeSummary {
        guestSummary ?? sampleSummary
    }

    private var visibleLogs: [SavingsLogRow] {
        guestLogs.isEmpty ? sampleLogs : guestLogs
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                ChallengeHeroCard(summary: visibleSummary)
                ChallengeGradeCard(summary: visibleSummary)

                ChallengeMonthCard(
                    summary: visibleSummary,
                    logs: visibleLogs,
                    isLoading: false,
                    message: guestLogs.isEmpty ? "체험 화면입니다. 실제 저장은 로그인 후 가능합니다." : "기기에 임시 저장된 체험 기록입니다. 로그인 전까지 DB에는 저장되지 않아요.",
                    isSaving: false,
                    canCancelLogs: false,
                    onCancel: { _ in }
                )

                if guestLogs.isEmpty == false {
                    Button {
                        GuestChallengeStore.clear()
                        guestSummary = GuestChallengeStore.previewSummary()
                        guestLogs = GuestChallengeStore.previewLogs()
                    } label: {
                        Label("체험 기록 비우기", systemImage: "trash.fill")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(Brand.red)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Color(hex: "#FEF2F2"))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    isShowingShareCard = true
                } label: {
                    Label("공유 카드 미리보기", systemImage: "square.and.arrow.up.fill")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(Brand.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
        }
        .background(Brand.gray50)
        .navigationTitle("1억 챌린지 체험")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guestSummary = GuestChallengeStore.previewSummary()
            guestLogs = GuestChallengeStore.previewLogs()
        }
        .sheet(isPresented: $isShowingShareCard) {
            GradeShareCardView(summary: visibleSummary)
                .presentationDetents([.medium, .large])
        }
    }
}

struct ChallengeSummaryCard: View {
    let isSignedIn: Bool
    let isLoading: Bool
    let summary: ChallengeSummary?
    let message: String?
    let session: AuthSession?
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("1억 챌린지")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text("절약이 자산이 되는 순간")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                Spacer()

                if isLoading {
                    ProgressView()
                        .tint(Brand.primary)
                }
            }

            if !isSignedIn {
                VStack(alignment: .leading, spacing: 10) {
                    Text("로그인하면 나의 누적 절약액과 등급을 볼 수 있어요.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.gray500)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Brand.gray50)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    NavigationLink {
                        ChallengePreviewView()
                    } label: {
                        Label("1억 챌린지 체험 화면 보기", systemImage: "sparkles")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(Brand.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 42)
                            .background(Brand.blue50)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            } else if let summary {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("누적 절약액")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Brand.gray500)
                            Text(summary.currentSavingsText)
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Brand.price)
                        }

                        Spacer()

                        Text(summary.challengeGrade)
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(Color(hex: "#78350F"))
                            .background(Color(hex: "#FEF3C7"))
                            .clipShape(RoundedRectangle(cornerRadius: 9))
                    }

                    ProgressView(value: summary.progressFraction)
                        .tint(Brand.primary)

                    HStack {
                        Text("달성률 \(summary.progressPercentText)")
                        Spacer()
                        Text("남은 금액 \(summary.remainingText)")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.gray500)

                    if let session {
                        NavigationLink {
                            ChallengeView(session: session)
                        } label: {
                            Text("자세히 보기")
                                .font(.subheadline.weight(.heavy))
                                .foregroundStyle(Brand.primary)
                                .frame(maxWidth: .infinity)
                                .frame(height: 42)
                                .background(Brand.blue50)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message ?? "1억 챌린지를 불러오는 중이에요.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.gray500)
                    Button("새로고침", action: onRefresh)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.primary)
                }
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Brand.gray200, lineWidth: 1)
        )
    }
}

struct VisitSavingSheet: View {
    let place: Place
    let session: AuthSession
    let onLogged: (ChallengeSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: ChallengeViewModel
    @State private var selectedMenuID: UUID?
    @State private var customSavedAmount = ""

    private var selectedMenu: MenuItem? {
        if let selectedMenuID {
            return place.menus.first { $0.id == selectedMenuID }
        }
        return place.menus.first
    }

    private var actualPrice: Int {
        selectedMenu?.price ?? place.basePrice
    }

    private var estimatedOriginalPrice: Int {
        if let referencePrice = selectedMenu?.referencePrice, referencePrice > actualPrice {
            return referencePrice
        }
        return ChallengePriceEstimator.referencePrice(for: place.category, actualPrice: actualPrice)
    }

    private var estimatedSavedAmount: Int {
        max(estimatedOriginalPrice - actualPrice, 0)
    }

    private var savedAmount: Int {
        Int(customSavedAmount.filter(\.isNumber)) ?? estimatedSavedAmount
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(place.name)
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Brand.gray900)
                        Text("이번 방문에서 아낀 금액을 1억 챌린지에 기록해요.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.gray500)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("메뉴 선택")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)

                        ForEach(place.menus) { menu in
                            Button {
                                selectedMenuID = menu.id
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedMenu?.id == menu.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedMenu?.id == menu.id ? Brand.primary : Brand.gray300)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(menu.name)
                                            .font(.subheadline.weight(.heavy))
                                            .foregroundStyle(Brand.gray900)
                                        Text("\(menu.price.formatted())원")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Brand.price)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(selectedMenu?.id == menu.id ? Brand.blue50 : Brand.gray50)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("절약액 확인")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)

                        HStack {
                            Text("일반 기준가")
                            Spacer()
                            Text("\(estimatedOriginalPrice.formatted())원")
                        }
                        HStack {
                            Text("짠테크 이용가")
                            Spacer()
                            Text("\(actualPrice.formatted())원")
                                .foregroundStyle(Brand.price)
                        }
                        HStack {
                            Text("이번 방문 절약액")
                                .font(.subheadline.weight(.heavy))
                            Spacer()
                            Text("+\(savedAmount.formatted())원")
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Brand.price)
                        }

                        TextField("절약액 직접 입력", text: $customSavedAmount)
                            .keyboardType(.numberPad)
                            .padding(12)
                            .background(Brand.gray50)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        Text(referencePriceHelpText)
                            .font(.caption)
                            .foregroundStyle(Brand.gray500)
                    }
                    .font(.subheadline)
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    if let message = viewModel.message {
                        Text(message)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.gray500)
                    }
                }
                .padding(14)
            }
            .background(Brand.gray50)
            .navigationTitle("방문 완료")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isSaving ? "저장 중" : "기록") {
                        Task {
                            await submit()
                        }
                    }
                    .disabled(viewModel.isSaving || savedAmount <= 0)
                }
            }
        }
        .onAppear {
            selectedMenuID = selectedMenuID ?? place.menus.first?.id
        }
    }

    private func submit() async {
        let draft = SavingLogRequest(
            placeID: place.id,
            menuID: selectedMenu?.id,
            placeName: place.name,
            menuName: selectedMenu?.name,
            savedAmount: savedAmount,
            originalPrice: estimatedOriginalPrice,
            actualPrice: actualPrice,
            category: place.category.databaseValue,
            source: "visit"
        )

        guard let summary = await viewModel.logSaving(draft, session: session) else {
            return
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        onLogged(summary)
        dismiss()
    }

    private var referencePriceHelpText: String {
        if let referencePrice = selectedMenu?.referencePrice, referencePrice > actualPrice {
            return "메뉴별 일반 기준가를 바탕으로 절약액을 계산했어요."
        }
        return "아직 기준가가 부족해 카테고리 평균 기준으로 절약액을 계산했어요."
    }
}

struct VisitSavingPreviewSheet: View {
    let place: Place

    @Environment(\.dismiss) private var dismiss
    @State private var selectedMenuID: UUID?
    @State private var customSavedAmount = ""
    @State private var message: String?

    private var selectedMenu: MenuItem? {
        if let selectedMenuID {
            return place.menus.first { $0.id == selectedMenuID }
        }
        return place.menus.first
    }

    private var actualPrice: Int {
        selectedMenu?.price ?? place.basePrice
    }

    private var estimatedOriginalPrice: Int {
        if let referencePrice = selectedMenu?.referencePrice, referencePrice > actualPrice {
            return referencePrice
        }
        return ChallengePriceEstimator.referencePrice(for: place.category, actualPrice: actualPrice)
    }

    private var estimatedSavedAmount: Int {
        max(estimatedOriginalPrice - actualPrice, 0)
    }

    private var savedAmount: Int {
        Int(customSavedAmount.filter(\.isNumber)) ?? estimatedSavedAmount
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("방문 완료 체험")
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Brand.gray900)
                        Text(place.name)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Brand.primary)
                        Text("로그인 전에도 이번 방문 절약액이 어떻게 계산되는지 미리 볼 수 있어요.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.gray500)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("메뉴 선택")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)

                        ForEach(place.menus) { menu in
                            Button {
                                selectedMenuID = menu.id
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: selectedMenu?.id == menu.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selectedMenu?.id == menu.id ? Brand.primary : Brand.gray300)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(menu.name)
                                            .font(.subheadline.weight(.heavy))
                                            .foregroundStyle(Brand.gray900)
                                        Text("\(menu.price.formatted())원")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Brand.price)
                                    }
                                    Spacer()
                                }
                                .padding(12)
                                .background(selectedMenu?.id == menu.id ? Brand.blue50 : Brand.gray50)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("절약액 미리보기")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)

                        HStack {
                            Text("일반 기준가")
                            Spacer()
                            Text("\(estimatedOriginalPrice.formatted())원")
                        }
                        HStack {
                            Text("짠테크 이용가")
                            Spacer()
                            Text("\(actualPrice.formatted())원")
                                .foregroundStyle(Brand.price)
                        }
                        HStack {
                            Text("예상 절약액")
                                .font(.subheadline.weight(.heavy))
                            Spacer()
                            Text("+\(savedAmount.formatted())원")
                                .font(.title3.weight(.heavy))
                                .foregroundStyle(Brand.price)
                        }

                        TextField("절약액 직접 입력", text: $customSavedAmount)
                            .keyboardType(.numberPad)
                            .padding(12)
                            .background(Brand.gray50)
                            .clipShape(RoundedRectangle(cornerRadius: 12))

                        Text("체험 기록은 이 기기에만 임시 저장됩니다. 로그인하면 실제 1억 챌린지에 반영할 수 있어요.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.gray500)
                            .lineSpacing(2)
                    }
                    .font(.subheadline)
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    Button {
                        saveGuestLog()
                    } label: {
                        Text("체험 기록 저장")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Brand.primary)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                    .disabled(savedAmount <= 0)

                    Button {
                        dismiss()
                    } label: {
                        Text("닫고 MY 탭에서 로그인하기")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(Brand.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Brand.blue50)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    if let message {
                        Text(message)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Brand.price)
                    }
                }
                .padding(14)
            }
            .background(Brand.gray50)
            .navigationTitle("방문 완료 체험")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            selectedMenuID = selectedMenuID ?? place.menus.first?.id
        }
    }

    private func saveGuestLog() {
        guard savedAmount > 0 else {
            message = "절약액은 1원 이상이어야 해요."
            return
        }

        GuestChallengeStore.append(
            GuestSavingLog(
                id: UUID(),
                placeID: place.id,
                menuID: selectedMenu?.id,
                placeName: place.name,
                menuName: selectedMenu?.name,
                savedAmount: savedAmount,
                originalPrice: estimatedOriginalPrice,
                actualPrice: actualPrice,
                category: place.category.databaseValue,
                createdAt: Date()
            )
        )
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        message = "체험 기록을 저장했어요. MY의 1억 챌린지 체험 화면에서 확인할 수 있어요."
    }
}

enum ChallengePriceEstimator {
    static func referencePrice(for category: PlaceCategory, actualPrice: Int) -> Int {
        switch category {
        case .food:
            return max(12000, actualPrice + 3000)
        case .cafe:
            return max(5000, actualPrice + 1500)
        case .hair:
            return max(18000, actualPrice + 5000)
        case .lodging:
            return max(70000, actualPrice + 10000)
        }
    }
}

private struct ChallengeHeroCard: View {
    let summary: ChallengeSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1억 챌린지")
                .font(.title.weight(.heavy))
                .foregroundStyle(.white)

            Text("절약이 자산이 되는 순간")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Brand.blue100)

            if let summary {
                VStack(alignment: .leading, spacing: 7) {
                    Text("1억까지 \(summary.remainingText) 남았어요")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white)
                    Text("절약으로 만든 자산 \(summary.currentSavingsText)")
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(Color(hex: "#BBF7D0"))
                }

                ProgressView(value: summary.progressFraction)
                    .tint(Color(hex: "#FBBF24"))

                HStack {
                    Text("현재 등급: \(summary.challengeGrade)")
                    Spacer()
                    Text(summary.progressPercentText)
                }
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [Brand.primary, Brand.primary700],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }
}

private struct ChallengeGradeCard: View {
    let summary: ChallengeSummary?

    private let grades = [
        ("흙수저", 0),
        ("짠돌이", 100000),
        ("절약러", 1000000),
        ("재테크 고수", 10000000),
        ("헬조선 생존자", 50000000),
        ("1억 달성자", 100000000)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("생존 등급")
                .font(.headline.weight(.heavy))
                .foregroundStyle(Brand.gray900)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(grades, id: \.0) { grade, amount in
                    Text(grade)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(isCurrent(grade) ? Brand.primary : Brand.gray700)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(isCurrent(grade) ? Brand.blue50 : Brand.gray50)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(isCurrent(grade) ? Brand.primary : Brand.gray200, lineWidth: 1)
                        )
                        .accessibilityLabel("\(grade), 기준 \(amount.formatted())원")
                }
            }

            if let summary {
                Text(nextGradeText(summary: summary))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Brand.gray500)
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func isCurrent(_ grade: String) -> Bool {
        summary?.challengeGrade == grade
    }

    private func nextGradeText(summary: ChallengeSummary) -> String {
        guard let next = grades.first(where: { $0.1 > summary.currentSavings }) else {
            return "1억 달성자 등급에 도착했어요."
        }
        let needed = next.1 - summary.currentSavings
        return "다음 등급 '\(next.0)'까지 \(needed.formatted())원 남았어요."
    }
}

private struct ChallengeMonthCard: View {
    let summary: ChallengeSummary?
    let logs: [SavingsLogRow]
    let isLoading: Bool
    let message: String?
    let isSaving: Bool
    let canCancelLogs: Bool
    let onCancel: (SavingsLogRow) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("이번 달 절약")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text(summary?.monthlySavingsText ?? "+0원")
                        .font(.title2.weight(.heavy))
                        .foregroundStyle(Brand.price)
                }
                Spacer()
                Text("\(summary?.logCount ?? 0)회 기록")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Brand.gray500)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Brand.gray50)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            if isLoading {
                ProgressView()
                    .tint(Brand.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else if logs.isEmpty {
                Text(message ?? "장소 상세에서 방문 완료를 눌러 첫 절약을 기록해보세요.")
                    .font(.subheadline)
                    .foregroundStyle(Brand.gray500)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Brand.gray50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                if let message {
                    Text(message)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(message.contains("취소") || message.contains("기록") ? Brand.price : Brand.gray500)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Brand.gray50)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                VStack(spacing: 0) {
                    ForEach(logs.prefix(8)) { log in
                        SavingsLogRowView(
                            log: log,
                            isSaving: isSaving,
                            canCancel: canCancelLogs,
                            onCancel: {
                                onCancel(log)
                            }
                        )
                    }
                }
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

private struct SavingsLogRowView: View {
    let log: SavingsLogRow
    let isSaving: Bool
    let canCancel: Bool
    let onCancel: () -> Void
    @State private var isShowingCancelConfirm = false

    var body: some View {
        HStack(spacing: 10) {
            Text(log.iconText)
                .font(.title3)
                .frame(width: 36, height: 36)
                .background(Brand.gray50)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(log.titleText)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Brand.gray900)
                    .lineLimit(1)
                Text(log.dateText)
                    .font(.caption)
                    .foregroundStyle(Brand.gray500)
                if log.source == "preview" {
                    Text("예시")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(Brand.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Brand.blue50)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                }
            }

            Spacer()

            Text(log.savedAmountText)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Brand.price)

            if canCancel {
                Button {
                    isShowingCancelConfirm = true
                } label: {
                    Text("취소")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Brand.red)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color(hex: "#FEF2F2"))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
        .padding(.vertical, 9)
        .alert("절약 기록을 취소할까요?", isPresented: $isShowingCancelConfirm) {
            Button("계속 보관", role: .cancel) {}
            Button("취소하기", role: .destructive) {
                onCancel()
            }
        } message: {
            Text("\(log.titleText)의 \(log.savedAmountText) 기록이 챌린지 누적액에서 빠져요.")
        }
    }
}

struct GradeShareCardView: View {
    let summary: ChallengeSummary
    @State private var isShowingShareSheet = false

    private var shareText: String {
        """
        나는 지금 \(summary.challengeGrade) 등급
        절약으로 만든 자산 \(summary.currentSavingsText)
        1억까지 \(summary.remainingText)
        #짠테크 #1억챌린지 #절약이자산이되는순간
        """
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                Text("짠테크")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color(hex: "#BFDBFE"))

                Text("나는 지금\n\(summary.challengeGrade) 등급")
                    .font(.title.weight(.heavy))
                    .foregroundStyle(.white)

                VStack(alignment: .leading, spacing: 7) {
                    Text("절약으로 만든 자산")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color(hex: "#BFDBFE"))
                    Text(summary.currentSavingsText)
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(Color(hex: "#BBF7D0"))
                }

                Text("1억까지 \(summary.remainingText)")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Color(hex: "#FDE68A"))

                Text("#짠테크 #1억챌린지 #절약이자산이되는순간")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white.opacity(0.86))
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [Brand.primary700, Brand.primary, Color(hex: "#0F766E")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .padding(.horizontal, 18)

            Button {
                isShowingShareSheet = true
            } label: {
                Label("문구 공유하기", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Brand.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)

            Spacer()
        }
        .padding(.top, 24)
        .background(Brand.gray50)
        .sheet(isPresented: $isShowingShareSheet) {
            ChallengeShareSheet(items: [shareText])
                .presentationDetents([.medium])
        }
    }
}

struct ChallengeShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
