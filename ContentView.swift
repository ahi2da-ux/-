import SwiftUI
import CoreLocation
import PhotosUI
import UIKit
import Security

#if canImport(NMapsMap)
import NMapsMap
#endif

private enum AppEnvironment {
    // 베타 사용자 화면에서는 내부 QA 도구와 샘플 계정 안내를 숨깁니다.
    // 필요할 때만 이 값을 true로 바꿔 내부 점검용 빌드를 만들 수 있습니다.
    static let showsInternalTools = false
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: MainTab = .map
    @StateObject private var placesViewModel = PlacesViewModel()
    @StateObject private var authManager = AuthManager()
    @StateObject private var favoritesViewModel = FavoritesViewModel()
    @StateObject private var challengeViewModel = ChallengeViewModel()

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ExploreView()
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem {
                Label("탐색", systemImage: "magnifyingglass")
            }
            .tag(MainTab.explore)

            NavigationStack {
                MapExploreView()
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem {
                Label("지도", systemImage: "map.fill")
            }
            .tag(MainTab.map)

            NavigationStack {
                V2EmptyView(
                    title: "청년",
                    subtitle: "청년 정책, 주거, 금융 콘텐츠는 v2에서 만나요.",
                    systemImage: "graduationcap.fill",
                    accent: Brand.indigo
                )
                .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem {
                Label("청년", systemImage: "graduationcap.fill")
            }
            .tag(MainTab.youth)

            NavigationStack {
                V2EmptyView(
                    title: "벼룩",
                    subtitle: "5만원 이하 위치 기반 중고거래는 v2에서 준비 중이에요.",
                    systemImage: "bag.fill",
                    accent: Brand.amber
                )
                .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem {
                Label("벼룩", systemImage: "bag.fill")
            }
            .tag(MainTab.flea)

            NavigationStack {
                MyPageView()
                    .toolbar(.hidden, for: .navigationBar)
            }
            .tabItem {
                Label("MY", systemImage: "person.fill")
            }
            .tag(MainTab.my)
        }
        .tint(Brand.primary)
        .environmentObject(placesViewModel)
        .environmentObject(authManager)
        .environmentObject(favoritesViewModel)
        .environmentObject(challengeViewModel)
        .task {
            await placesViewModel.loadPlaces()
            await authManager.restoreSession()
            if let session = authManager.session {
                await favoritesViewModel.loadFavorites(session: session)
                await challengeViewModel.load(session: session)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task {
                await authManager.refreshSessionIfNeeded()
            }
        }
        .onOpenURL { url in
            authManager.handlePasswordResetURL(url)
        }
        .sheet(
            isPresented: Binding(
                get: { authManager.passwordResetSession != nil },
                set: { isPresented in
                    if !isPresented {
                        authManager.cancelPasswordReset()
                    }
                }
            )
        ) {
            if let recoverySession = authManager.passwordResetSession {
                PasswordResetSheet(
                    recoverySession: recoverySession,
                    isLoading: authManager.isLoading,
                    message: authManager.authMessage,
                    onSubmit: { newPassword in
                        Task {
                            await authManager.updateRecoveredPassword(newPassword)
                        }
                    },
                    onCancel: {
                        authManager.cancelPasswordReset()
                    }
                )
            }
        }
        .onChange(of: authManager.session?.userID) { _, _ in
            guard let session = authManager.session else {
                favoritesViewModel.reset()
                challengeViewModel.reset()
                return
            }
            Task {
                await favoritesViewModel.loadFavorites(session: session)
                await challengeViewModel.load(session: session)
            }
        }
    }
}

// MARK: - Supabase Data Layer

@MainActor
private final class AuthManager: ObservableObject {
    @Published private(set) var session: AuthSession?
    @Published var passwordResetSession: PasswordResetSession?
    @Published private(set) var isLoading = false
    @Published var authMessage: String?

    private let repository = SupabaseAuthRepository()
    private let keychain = KeychainStore()

    var isSignedIn: Bool {
        session != nil
    }

    func restoreSession() async {
        guard session == nil else { return }
        do {
            if let savedSession = try keychain.loadSession() {
                if savedSession.needsRefresh {
                    let refreshedSession = try await repository.refreshSession(refreshToken: savedSession.refreshToken)
                    session = refreshedSession
                    try keychain.saveSession(refreshedSession)
                    authMessage = "로그인 상태를 안전하게 갱신했어요."
                } else {
                    session = savedSession
                    authMessage = "로그인 상태를 복원했어요."
                }
            }
        } catch {
            try? keychain.deleteSession()
            session = nil
            authMessage = "저장된 로그인 정보를 불러오지 못했어요."
        }
    }

    func refreshSessionIfNeeded(force: Bool = false) async {
        guard let currentSession = session else { return }
        guard force || currentSession.needsRefresh else { return }

        do {
            let refreshedSession = try await repository.refreshSession(refreshToken: currentSession.refreshToken)
            session = refreshedSession
            try keychain.saveSession(refreshedSession)
            authMessage = "로그인 상태를 갱신했어요."
        } catch {
            try? keychain.deleteSession()
            session = nil
            authMessage = "로그인 시간이 만료됐어요. 다시 로그인해주세요."
        }
    }

    func signUp(email: String, password: String, displayName: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        await authenticate {
            try await repository.signUp(email: trimmedEmail, password: password, displayName: trimmedDisplayName)
        }
    }

    func signIn(email: String, password: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        await authenticate {
            try await repository.signIn(email: trimmedEmail, password: password)
        }
    }

    func diagnoseAndSignIn(email: String, password: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@"), password.count >= 6 else {
            authMessage = "진단하려면 이메일과 6자 이상 비밀번호를 입력해주세요."
            return
        }

        isLoading = true
        authMessage = "Supabase 계정 상태를 점검하는 중이에요."
        defer { isLoading = false }

        do {
            let newSession = try await repository.signIn(email: trimmedEmail, password: password)
            session = newSession
            try keychain.saveSession(newSession)
            authMessage = "계정 정상 확인. 로그인까지 완료했어요."
        } catch AuthError.invalidCredentials {
            authMessage = "진단 결과: Supabase Auth에 이 이메일 유저가 없거나 비밀번호가 달라요. Users에서 유저 생성과 Confirm 상태를 확인해주세요."
        } catch AuthError.emailNotConfirmed {
            authMessage = "진단 결과: 계정은 있지만 Confirm 처리가 안 됐어요. Supabase Users에서 Confirm 처리해주세요."
        } catch {
            authMessage = "진단 실패: \(error.localizedDescription)"
        }
    }

    func sendPasswordReset(email: String) async {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedEmail.contains("@") else {
            authMessage = "비밀번호 재설정 메일을 받을 이메일을 입력해주세요."
            return
        }

        isLoading = true
        authMessage = nil
        defer { isLoading = false }

        do {
            try await repository.sendPasswordReset(email: trimmedEmail)
            authMessage = "비밀번호 재설정 메일을 보냈어요. 메일함을 확인해주세요."
        } catch {
            authMessage = error.localizedDescription
        }
    }

    func handlePasswordResetURL(_ url: URL) {
        guard let recoverySession = PasswordResetSession(url: url) else {
            return
        }
        passwordResetSession = recoverySession
        authMessage = "새 비밀번호를 입력해주세요."
    }

    func updateRecoveredPassword(_ newPassword: String) async {
        let trimmedPassword = newPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPassword.count >= 6 else {
            authMessage = "새 비밀번호는 6자 이상으로 입력해주세요."
            return
        }
        guard let recoverySession = passwordResetSession else {
            authMessage = "비밀번호 재설정 링크가 만료됐어요. 메일을 다시 받아주세요."
            return
        }

        isLoading = true
        authMessage = nil
        defer { isLoading = false }

        do {
            try await repository.updatePassword(
                newPassword: trimmedPassword,
                accessToken: recoverySession.accessToken
            )

            if let refreshToken = recoverySession.refreshToken {
                let refreshedSession = try await repository.refreshSession(refreshToken: refreshToken)
                session = refreshedSession
                try keychain.saveSession(refreshedSession)
            }

            passwordResetSession = nil
            authMessage = "비밀번호가 변경됐어요."
        } catch {
            authMessage = "비밀번호 변경에 실패했어요. 재설정 메일을 다시 받아주세요."
        }
    }

    func cancelPasswordReset() {
        passwordResetSession = nil
    }

    func signOut() {
        do {
            try keychain.deleteSession()
        } catch {
            authMessage = "로그아웃 저장소 정리에 실패했어요."
        }
        session = nil
        authMessage = "로그아웃했어요."
    }

    private func authenticate(_ work: () async throws -> AuthSession) async {
        isLoading = true
        authMessage = nil
        defer { isLoading = false }

        do {
            let newSession = try await work()
            session = newSession
            try keychain.saveSession(newSession)
            authMessage = "로그인 완료"
        } catch {
            authMessage = error.localizedDescription
        }
    }
}

private struct SupabaseAuthRepository {
    private let config = SupabaseConfig.current

    func signUp(email: String, password: String, displayName: String) async throws -> AuthSession {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        let payload = AuthSignUpRequest(
            email: email,
            password: password,
            data: ["display_name": displayName]
        )
        let data = try await sendAuthRequest(
            path: "auth/v1/signup",
            method: "POST",
            payload: payload,
            config: config
        )
        let response = try JSONDecoder().decode(AuthResponse.self, from: data)
        guard let session = response.toSession() else {
            throw AuthError.emailConfirmationRequired
        }
        return session
    }

    func signIn(email: String, password: String) async throws -> AuthSession {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        let payload = AuthPasswordRequest(email: email, password: password)
        let data = try await sendAuthRequest(
            path: "auth/v1/token",
            method: "POST",
            queryItems: [URLQueryItem(name: "grant_type", value: "password")],
            payload: payload,
            config: config
        )
        let response = try JSONDecoder().decode(AuthResponse.self, from: data)
        guard let session = response.toSession() else {
            throw AuthError.invalidAuthResponse
        }
        return session
    }

    func refreshSession(refreshToken: String) async throws -> AuthSession {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        let payload = AuthRefreshRequest(refreshToken: refreshToken)
        let data = try await sendAuthRequest(
            path: "auth/v1/token",
            method: "POST",
            queryItems: [URLQueryItem(name: "grant_type", value: "refresh_token")],
            payload: payload,
            config: config
        )
        let response = try JSONDecoder().decode(AuthResponse.self, from: data)
        guard let session = response.toSession() else {
            throw AuthError.invalidAuthResponse
        }
        return session
    }

    func sendPasswordReset(email: String) async throws {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        _ = try await sendAuthRequest(
            path: "auth/v1/recover",
            method: "POST",
            queryItems: [URLQueryItem(name: "redirect_to", value: PasswordResetSession.redirectURLString)],
            payload: AuthPasswordResetRequest(email: email),
            config: config
        )
    }

    func updatePassword(newPassword: String, accessToken: String) async throws {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var request = URLRequest(url: config.projectURL.appendingPathComponent("auth/v1/user"))
        request.httpMethod = "PUT"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(AuthPasswordUpdateRequest(password: newPassword))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabasePlacesError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "응답 본문 없음"
            throw AuthError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }
    }

    private func sendAuthRequest<T: Encodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem] = [],
        payload: T,
        config: SupabaseConfig
    ) async throws -> Data {
        var components = URLComponents(
            url: config.projectURL.appendingPathComponent(path),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = queryItems.isEmpty ? nil : queryItems

        guard let url = components?.url else {
            throw SupabasePlacesError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(config.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabasePlacesError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "응답 본문 없음"
            if body.contains("email_not_confirmed") {
                throw AuthError.emailNotConfirmed
            }
            if body.contains("invalid_credentials") {
                throw AuthError.invalidCredentials
            }
            if body.contains("email_address_invalid") {
                throw AuthError.invalidEmailAddress
            }
            if body.contains("over_email_send_rate_limit") {
                throw AuthError.emailRateLimit
            }
            throw AuthError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }

        return data
    }
}

struct AuthSession: Codable {
    let userID: UUID
    let email: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date?

    var needsRefresh: Bool {
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSinceNow < 300
    }
}

private struct PasswordResetSession: Identifiable {
    static let redirectURLString = "jjantechmap://password-reset"

    let id = UUID()
    let accessToken: String
    let refreshToken: String?
    let expiresAt: Date?

    init?(url: URL) {
        guard url.scheme == "jjantechmap", url.host == "password-reset" else {
            return nil
        }

        let values = Self.parameters(from: url)
        guard
            values["type"] == "recovery",
            let accessToken = values["access_token"],
            accessToken.isEmpty == false
        else {
            return nil
        }

        self.accessToken = accessToken
        self.refreshToken = values["refresh_token"]

        if let expiresAtString = values["expires_at"],
           let expiresAt = TimeInterval(expiresAtString) {
            self.expiresAt = Date(timeIntervalSince1970: expiresAt)
        } else if let expiresInString = values["expires_in"],
                  let expiresIn = TimeInterval(expiresInString) {
            self.expiresAt = Date().addingTimeInterval(expiresIn)
        } else {
            self.expiresAt = nil
        }
    }

    private static func parameters(from url: URL) -> [String: String] {
        var result: [String: String] = [:]

        func appendParameters(from text: String?) {
            guard let text, !text.isEmpty else { return }
            for pair in text.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                let key = parts[0].removingPercentEncoding ?? parts[0]
                let value = parts[1].removingPercentEncoding ?? parts[1]
                result[key] = value
            }
        }

        appendParameters(from: url.query)
        appendParameters(from: url.fragment)
        return result
    }
}

private struct AuthSignUpRequest: Encodable {
    let email: String
    let password: String
    let data: [String: String]
}

private struct AuthPasswordRequest: Encodable {
    let email: String
    let password: String
}

private struct AuthPasswordResetRequest: Encodable {
    let email: String
}

private struct AuthPasswordUpdateRequest: Encodable {
    let password: String
}

private struct AuthRefreshRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

private struct AuthResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int?
    let expiresAt: Int?
    let user: AuthUser?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case expiresAt = "expires_at"
        case user
    }

    func toSession() -> AuthSession? {
        guard
            let accessToken,
            let refreshToken,
            let user,
            let userID = UUID(uuidString: user.id)
        else {
            return nil
        }

        return AuthSession(
            userID: userID,
            email: user.email,
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: resolvedExpiresAt
        )
    }

    private var resolvedExpiresAt: Date? {
        if let expiresAt {
            return Date(timeIntervalSince1970: TimeInterval(expiresAt))
        }
        if let expiresIn {
            return Date().addingTimeInterval(TimeInterval(expiresIn))
        }
        return nil
    }
}

private struct AuthUser: Decodable {
    let id: String
    let email: String
}

private enum AuthError: LocalizedError {
    case invalidAuthResponse
    case emailConfirmationRequired
    case emailNotConfirmed
    case invalidCredentials
    case invalidEmailAddress
    case emailRateLimit
    case requestFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidAuthResponse:
            return "로그인 응답을 해석하지 못했어요."
        case .emailConfirmationRequired:
            return "회원가입은 완료됐어요. 이메일 확인 후 로그인해주세요."
        case .emailNotConfirmed:
            return "아직 이메일 확인이 끝나지 않았어요. 메일함에서 인증 링크를 눌러주세요."
        case .invalidCredentials:
            return "이메일 또는 비밀번호가 맞지 않아요. 계정 정보를 다시 확인해주세요."
        case .invalidEmailAddress:
            return "이메일 주소 형식이 올바르지 않아요. 실제로 받을 수 있는 이메일을 입력해주세요."
        case .emailRateLimit:
            return "Supabase 이메일 발송 제한에 걸렸어요. 대시보드에서 테스트 유저를 직접 만들고 Confirm 처리해주세요."
        case .requestFailed(let statusCode, _):
            return "인증 요청에 실패했어요. 잠시 후 다시 시도해주세요. (HTTP \(statusCode))"
        }
    }
}

private struct KeychainStore {
    private let service = "com.local.jjantechmap.runner"
    private let account = "supabase-auth-session"

    func saveSession(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        try deleteSession()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.requestFailed(statusCode: Int(status), body: "Keychain 저장 실패")
        }
    }

    func loadSession() throws -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw AuthError.requestFailed(statusCode: Int(status), body: "Keychain 조회 실패")
        }

        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    func deleteSession() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.requestFailed(statusCode: Int(status), body: "Keychain 삭제 실패")
        }
    }
}

@MainActor
private final class PlacesViewModel: ObservableObject {
    @Published private(set) var places: [Place] = Place.mock
    @Published private(set) var isLoading = false
    @Published private(set) var isUsingFallback = true
    @Published private(set) var statusMessage = "목업 데이터 사용 중"

    private let repository = SupabasePlacesRepository()

    func loadPlaces() async {
        guard !isLoading else { return }

        isLoading = true
        statusMessage = "Supabase에서 장소를 불러오는 중"

        do {
            let fetchedPlaces = try await repository.fetchPlaces()
            if fetchedPlaces.isEmpty {
                places = Place.mock
                isUsingFallback = true
                statusMessage = "DB 데이터가 비어 있어 목업 데이터로 표시 중"
            } else {
                places = fetchedPlaces
                isUsingFallback = false
                statusMessage = "Supabase DB 데이터 표시 중"
            }
        } catch {
            places = Place.mock
            isUsingFallback = true
            statusMessage = "DB 연결 실패 · 목업 데이터로 안전하게 표시 중"
            print("Supabase 장소 불러오기 실패:", error.localizedDescription)
        }

        isLoading = false
    }
}

private struct DataStatusBanner: View {
    @ObservedObject var viewModel: PlacesViewModel

    var body: some View {
        HStack(spacing: 8) {
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(Brand.primary)
            } else {
                Circle()
                    .fill(viewModel.isUsingFallback ? Brand.amber : Brand.price)
                    .frame(width: 8, height: 8)
            }

            Text(viewModel.statusMessage)
                .font(.caption.weight(.bold))
                .foregroundStyle(viewModel.isUsingFallback ? Brand.gray700 : Brand.price)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer()

            Button {
                Task {
                    await viewModel.loadPlaces()
                }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Brand.primary)
                    .frame(width: 28, height: 28)
                    .background(Brand.blue50)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Brand.gray200)
                .frame(height: 1)
        }
    }
}

private struct SupabasePlacesRepository {
    private let config = SupabaseConfig.current

    func fetchPlaces() async throws -> [Place] {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/places"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "*,menus(*)"),
            URLQueryItem(name: "order", value: "base_price.asc")
        ]

        guard let url = components?.url else {
            throw SupabasePlacesError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabasePlacesError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "응답 본문 없음"
            throw SupabasePlacesError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let rows = try decoder.decode([SupabasePlaceRow].self, from: data)
        return rows.compactMap { $0.toPlace() }
    }
}

struct SupabaseConfig {
    let projectURL: URL
    let publishableKey: String

    static var current: SupabaseConfig? {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SupabaseURL") as? String,
            let key = Bundle.main.object(forInfoDictionaryKey: "SupabasePublishableKey") as? String
        else {
            return nil
        }

        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let url = URL(string: trimmedURL),
            !trimmedKey.isEmpty,
            trimmedKey != "YOUR_SUPABASE_PUBLISHABLE_KEY"
        else {
            return nil
        }

        return SupabaseConfig(projectURL: url, publishableKey: trimmedKey)
    }
}

enum SupabasePlacesError: LocalizedError {
    case missingConfig
    case invalidURL
    case invalidResponse
    case requestFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .missingConfig:
            return "Info.plist에 SupabaseURL 또는 SupabasePublishableKey가 없습니다."
        case .invalidURL:
            return "Supabase REST API URL을 만들 수 없습니다."
        case .invalidResponse:
            return "Supabase 응답 형식이 올바르지 않습니다."
        case .requestFailed(let statusCode, let body):
            return "Supabase 요청 실패: HTTP \(statusCode), \(body)"
        }
    }
}

private struct SupabasePlaceRow: Decodable {
    let id: UUID
    let name: String
    let category: String
    let kind: String
    let icon: String
    let distanceText: String?
    let distanceTextShort: String?
    let basePrice: Int
    let rating: Double
    let reviewCount: Int
    let isVerified: Bool
    let verifyText: String?
    let isFeatured: Bool
    let trustScore: Int
    let receiptCount: Int
    let updatedText: String?
    let openTime: String?
    let statusText: String
    let address: String
    let stationNote: String?
    let latitude: Double
    let longitude: Double
    let tip: String?
    let menus: [SupabaseMenuRow]?

    func toPlace() -> Place? {
        guard let placeCategory = PlaceCategory(databaseValue: category) else {
            return nil
        }

        let menuItems = (menus ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { $0.toMenuItem() }

        return Place(
            id: id,
            name: name,
            category: placeCategory,
            kind: kind,
            icon: icon,
            distanceText: distanceText ?? "",
            distanceTextShort: distanceTextShort ?? "",
            basePrice: basePrice,
            rating: rating,
            reviewCount: reviewCount,
            isVerified: isVerified,
            verifyText: verifyText ?? "확인필요",
            isFeatured: isFeatured,
            trustScore: trustScore,
            receiptCount: receiptCount,
            updatedText: updatedText ?? "방금 확인",
            openTime: openTime ?? "-",
            statusText: statusText,
            address: address,
            stationNote: stationNote ?? "",
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            menus: menuItems,
            tip: tip ?? "아직 사용자 팁이 충분하지 않아요."
        )
    }
}

private struct SupabaseMenuRow: Decodable {
    let id: UUID
    let name: String
    let description: String?
    let price: Int
    let referencePrice: Int?
    let isVerified: Bool
    let sortOrder: Int

    func toMenuItem() -> MenuItem {
        MenuItem(
            id: id,
            name: name,
            description: description ?? "",
            price: price,
            referencePrice: referencePrice,
            verified: isVerified
        )
    }
}

private struct PriceReportRepository {
    private let config = SupabaseConfig.current

    func submit(_ draft: PriceReportDraft, images: [UIImage], session: AuthSession?) async throws {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        try await insertReport(draft, config: config, session: session)

        do {
            for (index, image) in images.enumerated() {
                let upload = try ImagePrivacyProcessor.makeSafeJPEGData(from: image)
                let path = "price_reports/\(draft.id.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"
                try await uploadPhotoData(upload.data, path: path, config: config, session: session)
                let photo = ReportPhotoDraft(
                    reportID: draft.id,
                    storagePath: path,
                    contentType: "image/jpeg",
                    fileSizeBytes: upload.data.count,
                    displayOrder: index
                )
                try await insertPhotoMetadata(photo, config: config, session: session)
            }

            try await updateReportUploadStatus(
                reportID: draft.id,
                status: "uploaded",
                config: config,
                session: session
            )
        } catch {
            try? await updateReportUploadStatus(
                reportID: draft.id,
                status: "upload_failed",
                config: config,
                session: session
            )
            throw error
        }
    }

    private func insertReport(_ draft: PriceReportDraft, config: SupabaseConfig, session: AuthSession?) async throws {
        let url = config.projectURL.appendingPathComponent("rest/v1/price_reports")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session?.accessToken ?? config.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(draft)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    private func uploadPhotoData(_ data: Data, path: String, config: SupabaseConfig, session: AuthSession?) async throws {
        let url = config.projectURL
            .appendingPathComponent("storage/v1/object/price-report-photos")
            .appendingPathComponent(path)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session?.accessToken ?? config.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("false", forHTTPHeaderField: "x-upsert")
        request.httpBody = data

        let (responseData, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: responseData)
    }

    private func insertPhotoMetadata(_ photo: ReportPhotoDraft, config: SupabaseConfig, session: AuthSession?) async throws {
        let url = config.projectURL.appendingPathComponent("rest/v1/rpc/insert_report_photo_metadata")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session?.accessToken ?? config.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(photo)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    private func updateReportUploadStatus(
        reportID: UUID,
        status: String,
        config: SupabaseConfig,
        session: AuthSession?
    ) async throws {
        let url = config.projectURL.appendingPathComponent("rest/v1/rpc/update_price_report_upload_status")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session?.accessToken ?? config.publishableKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            PriceReportUploadStatusRequest(reportID: reportID, uploadStatus: status)
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
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

private struct PriceReportDraft: Encodable {
    let id: UUID
    let userID: UUID?
    let placeID: UUID
    let menuName: String
    let reportedPrice: Int
    let visitDate: String
    let memo: String?
    let photoCount: Int
    let hasPhotoAttachment: Bool
    let reportStatus: String
    let rewardPoints: Int
    let uploadStatus: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case placeID = "place_id"
        case menuName = "menu_name"
        case reportedPrice = "reported_price"
        case visitDate = "visit_date"
        case memo
        case photoCount = "photo_count"
        case hasPhotoAttachment = "has_photo_attachment"
        case reportStatus = "report_status"
        case rewardPoints = "reward_points"
        case uploadStatus = "upload_status"
    }
}

private struct PriceReportUploadStatusRequest: Encodable {
    let reportID: UUID
    let uploadStatus: String

    enum CodingKeys: String, CodingKey {
        case reportID = "p_report_id"
        case uploadStatus = "p_upload_status"
    }
}

private struct ReportPhotoDraft: Encodable {
    let reportID: UUID
    let storagePath: String
    let contentType: String
    let fileSizeBytes: Int
    let displayOrder: Int

    enum CodingKeys: String, CodingKey {
        case reportID = "p_report_id"
        case storagePath = "p_storage_path"
        case contentType = "p_content_type"
        case fileSizeBytes = "p_file_size_bytes"
        case displayOrder = "p_display_order"
    }
}

private struct UserProfileRow: Identifiable, Decodable {
    let id: UUID
    let email: String?
    let displayName: String?
    let pointBalance: Int
    let reportCount: Int
    let acceptedReportCount: Int
    let updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case displayName = "display_name"
        case pointBalance = "point_balance"
        case reportCount = "report_count"
        case acceptedReportCount = "accepted_report_count"
        case updatedAt = "updated_at"
    }
}

@MainActor
private final class ProfileViewModel: ObservableObject {
    @Published private(set) var profile: UserProfileRow?
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    private let repository = ProfileRepository()

    var pointBalanceText: String {
        "\(profile?.pointBalance ?? 0) P"
    }

    var acceptedReportCountText: String {
        "\(profile?.acceptedReportCount ?? 0)"
    }

    var displayNameText: String {
        let trimmedName = profile?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmedName.isEmpty ? "짠테커" : trimmedName
    }

    func loadProfile(session: AuthSession) async {
        isLoading = true
        message = nil
        defer { isLoading = false }

        do {
            profile = try await repository.fetchProfile(session: session)
            if profile == nil {
                message = "프로필 정보가 아직 생성되지 않았어요."
            }
        } catch {
            message = "프로필과 포인트 정보를 불러오지 못했어요."
            print("프로필 조회 실패:", error.localizedDescription)
        }
    }

    func reset() {
        profile = nil
        isLoading = false
        message = nil
    }
}

private struct ProfileRepository {
    private let config = SupabaseConfig.current

    func fetchProfile(session: AuthSession) async throws -> UserProfileRow? {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/profiles"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "select",
                value: "id,email,display_name,point_balance,report_count,accepted_report_count,updated_at"
            ),
            URLQueryItem(name: "id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "limit", value: "1")
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
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabasePlacesError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "응답 본문 없음"
            throw SupabasePlacesError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }

        return try JSONDecoder().decode([UserProfileRow].self, from: data).first
    }
}

@MainActor
private final class PointTransactionsViewModel: ObservableObject {
    @Published private(set) var transactions: [PointTransactionRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    private let repository = PointTransactionsRepository()

    func loadTransactions(session: AuthSession) async {
        isLoading = true
        message = nil
        defer { isLoading = false }

        do {
            transactions = try await repository.fetchTransactions(session: session)
            if transactions.isEmpty {
                message = "아직 포인트 적립 내역이 없어요."
            }
        } catch {
            transactions = []
            message = "포인트 내역을 불러오지 못했어요."
            print("포인트 내역 조회 실패:", error.localizedDescription)
        }
    }

    func reset() {
        transactions = []
        isLoading = false
        message = nil
    }
}

private struct PointTransactionsRepository {
    private let config = SupabaseConfig.current

    func fetchTransactions(session: AuthSession) async throws -> [PointTransactionRow] {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/point_transactions"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "select",
                value: "id,user_id,report_id,amount,transaction_type,title,description,created_by,created_at"
            ),
            URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "20")
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
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabasePlacesError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "응답 본문 없음"
            throw SupabasePlacesError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }

        return try JSONDecoder().decode([PointTransactionRow].self, from: data)
    }
}

@MainActor
private final class FavoritesViewModel: ObservableObject {
    @Published private(set) var favoritePlaceIDs: Set<UUID> = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    private let repository = FavoritesRepository()

    func isFavorite(_ place: Place) -> Bool {
        favoritePlaceIDs.contains(place.id)
    }

    func loadFavorites(session: AuthSession) async {
        isLoading = true
        message = nil
        defer { isLoading = false }

        do {
            let rows = try await repository.fetchFavorites(session: session)
            favoritePlaceIDs = Set(rows.map(\.placeID))
        } catch {
            message = "즐겨찾기를 불러오지 못했어요."
            print("즐겨찾기 조회 실패:", error.localizedDescription)
        }
    }

    func toggle(place: Place, session: AuthSession) async -> Bool {
        let wasFavorite = favoritePlaceIDs.contains(place.id)
        if wasFavorite {
            favoritePlaceIDs.remove(place.id)
        } else {
            favoritePlaceIDs.insert(place.id)
        }

        do {
            if wasFavorite {
                try await repository.deleteFavorite(placeID: place.id, session: session)
            } else {
                try await repository.insertFavorite(placeID: place.id, session: session)
            }
            message = wasFavorite ? "즐겨찾기에서 뺐어요." : "즐겨찾기에 추가했어요."
            return !wasFavorite
        } catch {
            if wasFavorite {
                favoritePlaceIDs.insert(place.id)
            } else {
                favoritePlaceIDs.remove(place.id)
            }
            message = "즐겨찾기 저장에 실패했어요."
            print("즐겨찾기 저장 실패:", error.localizedDescription)
            return wasFavorite
        }
    }

    func reset() {
        favoritePlaceIDs = []
        isLoading = false
        message = nil
    }
}

private struct FavoritesRepository {
    private let config = SupabaseConfig.current

    func fetchFavorites(session: AuthSession) async throws -> [FavoritePlaceRow] {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/favorite_places"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,user_id,place_id,created_at"),
            URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "order", value: "created_at.desc")
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
        return try JSONDecoder().decode([FavoritePlaceRow].self, from: data)
    }

    func insertFavorite(placeID: UUID, session: AuthSession) async throws {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        let url = config.projectURL.appendingPathComponent("rest/v1/favorite_places")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("resolution=ignore-duplicates,return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(FavoritePlaceDraft(userID: session.userID, placeID: placeID))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
    }

    func deleteFavorite(placeID: UUID, session: AuthSession) async throws {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/favorite_places"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "place_id", value: "eq.\(placeID.uuidString.lowercased())")
        ]

        guard let url = components?.url else {
            throw SupabasePlacesError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
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

@MainActor
private final class PriceAlertSettingsViewModel: ObservableObject {
    @Published private(set) var settingsByPlaceID: [UUID: PriceAlertSettingRow] = [:]
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var message: String?

    private let repository = PriceAlertSettingsRepository()

    func setting(for place: Place) -> PriceAlertSettingRow? {
        settingsByPlaceID[place.id]
    }

    func isEnabled(for place: Place) -> Bool {
        settingsByPlaceID[place.id]?.isEnabled ?? false
    }

    func targetPriceText(for place: Place) -> String {
        guard let targetPrice = settingsByPlaceID[place.id]?.targetPrice else {
            return "목표가 없음"
        }
        return "\(targetPrice.formatted())원 이하"
    }

    func loadSettings(session: AuthSession) async {
        isLoading = true
        message = nil
        defer { isLoading = false }

        do {
            let rows = try await repository.fetchSettings(session: session)
            settingsByPlaceID = Dictionary(uniqueKeysWithValues: rows.map { ($0.placeID, $0) })
            if rows.isEmpty {
                message = "아직 가격 알림 설정이 없어요."
            }
        } catch {
            settingsByPlaceID = [:]
            message = "가격 알림 설정을 불러오지 못했어요."
            print("가격 알림 설정 조회 실패:", error.localizedDescription)
        }
    }

    func toggle(place: Place, session: AuthSession) async {
        let current = settingsByPlaceID[place.id]
        let nextEnabled = !(current?.isEnabled ?? false)
        let targetPrice = current?.targetPrice ?? place.basePrice
        await save(place: place, isEnabled: nextEnabled, targetPrice: targetPrice, session: session)
    }

    func setTargetToCurrentPrice(place: Place, session: AuthSession) async {
        let isEnabled = settingsByPlaceID[place.id]?.isEnabled ?? true
        await save(place: place, isEnabled: isEnabled, targetPrice: place.basePrice, session: session)
    }

    func lowerTargetPrice(place: Place, session: AuthSession) async {
        let currentTarget = settingsByPlaceID[place.id]?.targetPrice ?? place.basePrice
        let nextTarget = max(500, currentTarget - 500)
        let isEnabled = settingsByPlaceID[place.id]?.isEnabled ?? true
        await save(place: place, isEnabled: isEnabled, targetPrice: nextTarget, session: session)
    }

    private func save(place: Place, isEnabled: Bool, targetPrice: Int?, session: AuthSession) async {
        isSaving = true
        message = nil
        defer { isSaving = false }

        let previous = settingsByPlaceID[place.id]
        let draft = PriceAlertSettingDraft(
            userID: session.userID,
            placeID: place.id,
            isEnabled: isEnabled,
            targetPrice: targetPrice
        )

        settingsByPlaceID[place.id] = PriceAlertSettingRow(
            id: previous?.id ?? UUID(),
            userID: session.userID,
            placeID: place.id,
            isEnabled: isEnabled,
            targetPrice: targetPrice,
            lastNotifiedAt: previous?.lastNotifiedAt,
            createdAt: previous?.createdAt ?? "",
            updatedAt: previous?.updatedAt ?? ""
        )

        do {
            let saved = try await repository.upsertSetting(draft, session: session)
            settingsByPlaceID[place.id] = saved
            message = isEnabled ? "가격 알림을 켰어요." : "가격 알림을 껐어요."
        } catch {
            if let previous {
                settingsByPlaceID[place.id] = previous
            } else {
                settingsByPlaceID.removeValue(forKey: place.id)
            }
            message = "가격 알림 설정 저장에 실패했어요."
            print("가격 알림 설정 저장 실패:", error.localizedDescription)
        }
    }

    func reset() {
        settingsByPlaceID = [:]
        isLoading = false
        isSaving = false
        message = nil
    }
}

private struct PriceAlertSettingsRepository {
    private let config = SupabaseConfig.current

    func fetchSettings(session: AuthSession) async throws -> [PriceAlertSettingRow] {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/price_alert_settings"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,user_id,place_id,is_enabled,target_price,last_notified_at,created_at,updated_at"),
            URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "order", value: "updated_at.desc")
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
        return try JSONDecoder().decode([PriceAlertSettingRow].self, from: data)
    }

    func upsertSetting(_ draft: PriceAlertSettingDraft, session: AuthSession) async throws -> PriceAlertSettingRow {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        let url = config.projectURL.appendingPathComponent("rest/v1/price_alert_settings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("resolution=merge-duplicates,return=representation", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(draft)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        guard let saved = try JSONDecoder().decode([PriceAlertSettingRow].self, from: data).first else {
            throw SupabasePlacesError.invalidResponse
        }
        return saved
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

@MainActor
private final class PriceAlertEventsViewModel: ObservableObject {
    @Published private(set) var events: [PriceAlertEventRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var message: String?

    private let repository = PriceAlertEventsRepository()

    var unreadCount: Int {
        events.filter { !$0.isRead }.count
    }

    func loadEvents(session: AuthSession) async {
        isLoading = true
        message = nil
        defer { isLoading = false }

        do {
            events = try await repository.fetchEvents(session: session)
            if events.isEmpty {
                message = "아직 가격 알림이 없어요."
            }
        } catch {
            events = []
            message = "가격 알림함을 불러오지 못했어요."
            print("가격 알림함 조회 실패:", error.localizedDescription)
        }
    }

    func markAsRead(_ event: PriceAlertEventRow, session: AuthSession) async {
        guard !event.isRead else { return }
        isSaving = true
        message = nil
        defer { isSaving = false }

        let previousEvents = events
        events = events.map { current in
            current.id == event.id ? current.markedRead() : current
        }

        do {
            try await repository.markAsRead(eventID: event.id, session: session)
            message = "알림을 읽음 처리했어요."
        } catch {
            events = previousEvents
            message = "알림 읽음 처리에 실패했어요."
            print("가격 알림 읽음 처리 실패:", error.localizedDescription)
        }
    }

    func reset() {
        events = []
        isLoading = false
        isSaving = false
        message = nil
    }
}

private struct PriceAlertEventsRepository {
    private let config = SupabaseConfig.current

    func fetchEvents(session: AuthSession) async throws -> [PriceAlertEventRow] {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/price_alert_events"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,user_id,place_id,report_id,title,message,target_price,matched_price,is_read,created_at"),
            URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "order", value: "created_at.desc"),
            URLQueryItem(name: "limit", value: "20")
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
        return try JSONDecoder().decode([PriceAlertEventRow].self, from: data)
    }

    func markAsRead(eventID: UUID, session: AuthSession) async throws {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        let url = config.projectURL.appendingPathComponent("rest/v1/rpc/mark_price_alert_event_read")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(PriceAlertEventReadRequest(targetEventID: eventID))

        let (data, response) = try await URLSession.shared.data(for: request)
        do {
            try validate(response: response, data: data)
        } catch SupabasePlacesError.requestFailed(let statusCode, let body)
            where statusCode == 404 || body.contains("mark_price_alert_event_read") || body.contains("PGRST202") {
            try await markAsReadWithTemporaryPatchFallback(eventID: eventID, session: session)
        }
    }

    private func markAsReadWithTemporaryPatchFallback(eventID: UUID, session: AuthSession) async throws {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/price_alert_events"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "id", value: "eq.\(eventID.uuidString.lowercased())"),
            URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString.lowercased())")
        ]

        guard let url = components?.url else {
            throw SupabasePlacesError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONEncoder().encode(PriceAlertEventReadPatch(isRead: true))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
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

@MainActor
private final class MyReportsViewModel: ObservableObject {
    @Published private(set) var reports: [MyPriceReportRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?

    private let repository = MyReportsRepository()

    var totalCount: Int {
        reports.count
    }

    var approvedCount: Int {
        reports.filter { $0.reportStatus == "approved" }.count
    }

    var expectedPoints: Int {
        reports.reduce(0) { $0 + $1.rewardPoints }
    }

    func loadReports(session: AuthSession) async {
        isLoading = true
        message = nil
        defer { isLoading = false }

        do {
            reports = try await repository.fetchReports(session: session)
            if reports.isEmpty {
                message = "아직 저장된 제보가 없어요."
            }
        } catch {
            message = "내 제보를 불러오지 못했어요. 잠시 후 다시 시도해주세요."
            print("내 제보 조회 실패:", error.localizedDescription)
        }
    }

    func reset() {
        reports = []
        message = nil
        isLoading = false
    }
}

private struct MyReportsRepository {
    private let config = SupabaseConfig.current

    func fetchReports(session: AuthSession) async throws -> [MyPriceReportRow] {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/price_reports"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "select",
                value: "id,menu_name,reported_price,visit_date,memo,photo_count,report_status,reward_points,upload_status,created_at,reviewed_at,review_note,rejection_reason,point_granted_at"
            ),
            URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "order", value: "created_at.desc")
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
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabasePlacesError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "응답 본문 없음"
            throw SupabasePlacesError.requestFailed(statusCode: httpResponse.statusCode, body: body)
        }

        let decoder = JSONDecoder()
        return try decoder.decode([MyPriceReportRow].self, from: data)
    }
}

@MainActor
private final class AdminReviewViewModel: ObservableObject {
    @Published private(set) var isAdmin = false
    @Published private(set) var pendingReports: [MyPriceReportRow] = []
    @Published private(set) var pipelineAudits: [ReportPipelineAuditRow] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var message: String?

    private let repository = AdminReviewRepository()

    var pendingCount: Int {
        pendingReports.count
    }

    var pipelineIssueCount: Int {
        pipelineAudits.filter { !$0.isOK }.count
    }

    func loadIfAdmin(session: AuthSession) async {
        isLoading = true
        message = nil
        defer { isLoading = false }

        do {
            isAdmin = try await repository.isAdmin(session: session)
            guard isAdmin else {
                pendingReports = []
                pipelineAudits = []
                return
            }
            async let pendingTask = repository.fetchPendingReports(session: session)
            async let auditTask = repository.fetchPipelineAudits(session: session)
            pendingReports = try await pendingTask
            pipelineAudits = try await auditTask
            if pendingReports.isEmpty && pipelineIssueCount == 0 {
                message = "검수 대기 중인 제보가 없어요."
            }
        } catch {
            isAdmin = false
            pendingReports = []
            pipelineAudits = []
            message = "운영자 정보를 불러오지 못했어요."
            print("운영자 검수 정보 조회 실패:", error.localizedDescription)
        }
    }

    func approve(report: MyPriceReportRow, note: String, session: AuthSession) async {
        await submitReview(session: session) {
            try await repository.approve(reportID: report.id, note: note, session: session)
        }
    }

    func reject(report: MyPriceReportRow, reason: String, note: String, session: AuthSession) async {
        await submitReview(session: session) {
            try await repository.reject(reportID: report.id, reason: reason, note: note, session: session)
        }
    }

    func repairPipeline(row: ReportPipelineAuditRow, session: AuthSession) async {
        isSubmitting = true
        message = nil
        defer { isSubmitting = false }

        do {
            pipelineAudits = try await repository.repairPipeline(reportID: row.reportID, session: session)
            message = "파이프라인 복구를 실행했어요."
        } catch {
            message = "파이프라인 복구에 실패했어요. 027번 SQL 실행 여부와 관리자 권한을 확인해주세요."
            print("운영자 파이프라인 복구 실패:", error.localizedDescription)
        }
    }

    func reset() {
        isAdmin = false
        pendingReports = []
        pipelineAudits = []
        isLoading = false
        isSubmitting = false
        message = nil
    }

    private func submitReview(session: AuthSession, work: () async throws -> Void) async {
        isSubmitting = true
        message = nil
        defer { isSubmitting = false }

        do {
            try await work()
            async let pendingTask = repository.fetchPendingReports(session: session)
            async let auditTask = repository.fetchPipelineAudits(session: session)
            pendingReports = try await pendingTask
            pipelineAudits = try await auditTask
            message = "검수 결과가 저장됐어요."
        } catch {
            message = "검수 저장에 실패했어요. 관리자 권한과 네트워크를 확인해주세요."
            print("운영자 검수 저장 실패:", error.localizedDescription)
        }
    }
}

private struct AdminReviewRepository {
    private let config = SupabaseConfig.current

    func isAdmin(session: AuthSession) async throws -> Bool {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/app_admins"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "user_id,role"),
            URLQueryItem(name: "user_id", value: "eq.\(session.userID.uuidString.lowercased())"),
            URLQueryItem(name: "limit", value: "1")
        ]

        let rows: [AdminAccountRow] = try await sendRequest(
            components: components,
            method: "GET",
            session: session
        )
        return !rows.isEmpty
    }

    func fetchPendingReports(session: AuthSession) async throws -> [MyPriceReportRow] {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/price_reports"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(
                name: "select",
                value: "id,user_id,place_id,menu_name,reported_price,visit_date,memo,photo_count,report_status,reward_points,upload_status,created_at,reviewed_at,review_note,rejection_reason,point_granted_at"
            ),
            URLQueryItem(name: "report_status", value: "eq.pending"),
            URLQueryItem(name: "upload_status", value: "eq.uploaded"),
            URLQueryItem(name: "order", value: "created_at.asc")
        ]

        return try await sendRequest(
            components: components,
            method: "GET",
            session: session
        )
    }

    func fetchPipelineAudits(session: AuthSession) async throws -> [ReportPipelineAuditRow] {
        try await sendRPCResponse(
            path: "get_report_pipeline_audit",
            payload: ReportPipelineAuditRequest(limit: 80),
            session: session
        )
    }

    func approve(reportID: UUID, note: String, session: AuthSession) async throws {
        let payload = ApproveReportRequest(
            targetReportID: reportID,
            adminNote: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        try await sendRPC(path: "approve_price_report", payload: payload, session: session)
    }

    func reject(reportID: UUID, reason: String, note: String, session: AuthSession) async throws {
        let payload = RejectReportRequest(
            targetReportID: reportID,
            reason: reason.trimmingCharacters(in: .whitespacesAndNewlines),
            adminNote: note.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        try await sendRPC(path: "reject_price_report", payload: payload, session: session)
    }

    func repairPipeline(reportID: UUID, session: AuthSession) async throws -> [ReportPipelineAuditRow] {
        try await sendRPCResponse(
            path: "repair_report_pipeline",
            payload: RepairReportPipelineRequest(targetReportID: reportID),
            session: session
        )
    }

    func fetchPhotoAttachments(reportID: UUID, session: AuthSession) async throws -> [ReportPhotoAttachment] {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        var components = URLComponents(
            url: config.projectURL.appendingPathComponent("rest/v1/report_photos"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "select", value: "id,report_id,storage_bucket,storage_path,content_type,file_size_bytes,display_order,created_at"),
            URLQueryItem(name: "report_id", value: "eq.\(reportID.uuidString.lowercased())"),
            URLQueryItem(name: "order", value: "display_order.asc")
        ]

        let rows: [ReportPhotoRow] = try await sendRequest(
            components: components,
            method: "GET",
            session: session
        )

        var attachments: [ReportPhotoAttachment] = []
        for row in rows {
            let url = try await makeSignedPhotoURL(path: row.storagePath, session: session)
            attachments.append(ReportPhotoAttachment(row: row, signedURL: url))
        }
        return attachments
    }

    private func sendRequest<T: Decodable>(
        components: URLComponents?,
        method: String,
        session: AuthSession
    ) async throws -> T {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }
        guard let url = components?.url else {
            throw SupabasePlacesError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendRPC<T: Encodable>(path: String, payload: T, session: AuthSession) async throws {
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
    }

    private func sendRPCResponse<T: Encodable, U: Decodable>(
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

    private func makeSignedPhotoURL(path: String, session: AuthSession) async throws -> URL {
        guard let config else {
            throw SupabasePlacesError.missingConfig
        }

        let url = config.projectURL
            .appendingPathComponent("storage/v1/object/sign/price-report-photos")
            .appendingPathComponent(path)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(SignedURLRequest(expiresIn: 600))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let signedResponse = try JSONDecoder().decode(SignedURLResponse.self, from: data)
        guard let signedURL = URL(string: signedResponse.signedURL, relativeTo: config.projectURL)?.absoluteURL else {
            throw SupabasePlacesError.invalidURL
        }
        return signedURL
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

private struct AdminAccountRow: Decodable {
    let userID: UUID
    let role: String

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case role
    }
}

private struct ReportPipelineAuditRequest: Encodable {
    let limit: Int

    enum CodingKeys: String, CodingKey {
        case limit = "p_limit"
    }
}

private struct ReportPipelineAuditRow: Identifiable, Decodable {
    let reportID: UUID
    let userID: UUID?
    let placeID: UUID
    let placeName: String?
    let menuName: String
    let reportedPrice: Int
    let reportStatus: String
    let reviewedAt: String?
    let menuID: UUID?
    let menuPrice: Int?
    let menuReferencePrice: Int?
    let expectedSavedAmount: Int
    let pointTransactionID: UUID?
    let pointAmount: Int?
    let savingsLogID: UUID?
    let savedAmount: Int?
    let savingsSource: String?
    let alertEventCount: Int
    let pipelineStatus: String

    var id: UUID { reportID }

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case userID = "user_id"
        case placeID = "place_id"
        case placeName = "place_name"
        case menuName = "menu_name"
        case reportedPrice = "reported_price"
        case reportStatus = "report_status"
        case reviewedAt = "reviewed_at"
        case menuID = "menu_id"
        case menuPrice = "menu_price"
        case menuReferencePrice = "menu_reference_price"
        case expectedSavedAmount = "expected_saved_amount"
        case pointTransactionID = "point_transaction_id"
        case pointAmount = "point_amount"
        case savingsLogID = "savings_log_id"
        case savedAmount = "saved_amount"
        case savingsSource = "savings_source"
        case alertEventCount = "alert_event_count"
        case pipelineStatus = "pipeline_status"
    }

    var isOK: Bool {
        pipelineStatus == "ok" || pipelineStatus == "not_approved"
    }

    var statusText: String {
        switch pipelineStatus {
        case "ok":
            return "정상"
        case "missing_menu":
            return "가격표 누락"
        case "missing_point":
            return "포인트 누락"
        case "missing_challenge_log":
            return "챌린지 누락"
        case "challenge_amount_mismatch":
            return "절약액 불일치"
        case "not_approved":
            return "승인 전"
        default:
            return pipelineStatus
        }
    }

    var statusColor: Color {
        isOK ? Brand.price : Brand.red
    }

    var summaryText: String {
        let place = placeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayPlace = (place?.isEmpty == false) ? place! : "장소 미확인"
        return "\(displayPlace) · \(menuName) \(reportedPrice.formatted())원"
    }
}

private struct ApproveReportRequest: Encodable {
    let targetReportID: UUID
    let adminNote: String?

    enum CodingKeys: String, CodingKey {
        case targetReportID = "target_report_id"
        case adminNote = "admin_note"
    }
}

private struct RejectReportRequest: Encodable {
    let targetReportID: UUID
    let reason: String
    let adminNote: String?

    enum CodingKeys: String, CodingKey {
        case targetReportID = "target_report_id"
        case reason
        case adminNote = "admin_note"
    }
}

private struct RepairReportPipelineRequest: Encodable {
    let targetReportID: UUID

    enum CodingKeys: String, CodingKey {
        case targetReportID = "target_report_id"
    }
}

private struct ReportPhotoRow: Identifiable, Decodable {
    let id: UUID
    let reportID: UUID
    let storageBucket: String
    let storagePath: String
    let contentType: String
    let fileSizeBytes: Int
    let displayOrder: Int
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case reportID = "report_id"
        case storageBucket = "storage_bucket"
        case storagePath = "storage_path"
        case contentType = "content_type"
        case fileSizeBytes = "file_size_bytes"
        case displayOrder = "display_order"
        case createdAt = "created_at"
    }

    var fileSizeLabel: String {
        let kb = max(1, fileSizeBytes / 1024)
        return "\(kb.formatted())KB"
    }
}

private struct ReportPhotoAttachment: Identifiable {
    let row: ReportPhotoRow
    let signedURL: URL

    var id: UUID {
        row.id
    }
}

private struct SignedURLRequest: Encodable {
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case expiresIn = "expiresIn"
    }
}

private struct SignedURLResponse: Decodable {
    let signedURL: String

    enum CodingKeys: String, CodingKey {
        case signedURL = "signedURL"
    }
}

private struct MyPriceReportRow: Identifiable, Decodable {
    let id: UUID
    let userID: UUID?
    let placeID: UUID?
    let menuName: String
    let reportedPrice: Int
    let visitDate: String?
    let memo: String?
    let photoCount: Int
    let reportStatus: String
    let rewardPoints: Int
    let uploadStatus: String?
    let createdAt: String
    let reviewedAt: String?
    let reviewNote: String?
    let rejectionReason: String?
    let pointGrantedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case placeID = "place_id"
        case menuName = "menu_name"
        case reportedPrice = "reported_price"
        case visitDate = "visit_date"
        case memo
        case photoCount = "photo_count"
        case reportStatus = "report_status"
        case rewardPoints = "reward_points"
        case uploadStatus = "upload_status"
        case createdAt = "created_at"
        case reviewedAt = "reviewed_at"
        case reviewNote = "review_note"
        case rejectionReason = "rejection_reason"
        case pointGrantedAt = "point_granted_at"
    }

    var statusLabel: String {
        switch reportStatus {
        case "approved":
            return "승인"
        case "rejected":
            return "반려"
        default:
            return "검수중"
        }
    }

    var statusColor: Color {
        switch reportStatus {
        case "approved":
            return Brand.price
        case "rejected":
            return Brand.red
        default:
            return Brand.amber
        }
    }

    var photoLabel: String {
        photoCount > 0 ? "사진 \(photoCount)장" : "사진 없음"
    }

    var uploadStatusLabel: String {
        switch uploadStatus {
        case "uploaded":
            return "사진 업로드 완료"
        case "upload_failed":
            return "사진 업로드 실패"
        case "pending_upload":
            return "사진 업로드 중"
        default:
            return photoCount > 0 ? "사진 확인 중" : "첨부 사진 없음"
        }
    }

    var createdDateLabel: String {
        String(createdAt.prefix(10))
    }

    var visitDateLabel: String {
        guard let visitDate, !visitDate.isEmpty else {
            return "방문일 미입력"
        }
        return visitDate
    }

    var reviewedDateLabel: String {
        guard let reviewedAt, !reviewedAt.isEmpty else {
            return "아직 검수 전"
        }
        return String(reviewedAt.prefix(10))
    }

    var pointGrantedDateLabel: String {
        guard let pointGrantedAt, !pointGrantedAt.isEmpty else {
            return "지급 대기"
        }
        return String(pointGrantedAt.prefix(10))
    }

    var reviewMessage: String {
        if reportStatus == "rejected", let rejectionReason, !rejectionReason.isEmpty {
            return rejectionReason
        }
        if let reviewNote, !reviewNote.isEmpty {
            return reviewNote
        }
        return "아직 운영자 검수 메모가 없어요."
    }
}

private struct PointTransactionRow: Identifiable, Decodable {
    let id: UUID
    let userID: UUID
    let reportID: UUID?
    let amount: Int
    let transactionType: String
    let title: String
    let description: String?
    let createdBy: UUID?
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case reportID = "report_id"
        case amount
        case transactionType = "transaction_type"
        case title
        case description
        case createdBy = "created_by"
        case createdAt = "created_at"
    }

    var amountLabel: String {
        let sign = amount > 0 ? "+" : ""
        return "\(sign)\(amount.formatted())P"
    }

    var amountColor: Color {
        amount >= 0 ? Brand.price : Brand.red
    }

    var typeLabel: String {
        switch transactionType {
        case "report_reward":
            return "제보 적립"
        case "manual_adjustment":
            return "운영 조정"
        case "spend":
            return "포인트 사용"
        default:
            return "포인트"
        }
    }

    var createdDateLabel: String {
        String(createdAt.prefix(10))
    }
}

private struct FavoritePlaceRow: Identifiable, Decodable {
    let id: UUID
    let userID: UUID
    let placeID: UUID
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case placeID = "place_id"
        case createdAt = "created_at"
    }
}

private struct FavoritePlaceDraft: Encodable {
    let userID: UUID
    let placeID: UUID

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case placeID = "place_id"
    }
}

private struct PriceAlertSettingRow: Identifiable, Decodable {
    let id: UUID
    let userID: UUID
    let placeID: UUID
    let isEnabled: Bool
    let targetPrice: Int?
    let lastNotifiedAt: String?
    let createdAt: String
    let updatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case placeID = "place_id"
        case isEnabled = "is_enabled"
        case targetPrice = "target_price"
        case lastNotifiedAt = "last_notified_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

private struct PriceAlertSettingDraft: Encodable {
    let userID: UUID
    let placeID: UUID
    let isEnabled: Bool
    let targetPrice: Int?

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case placeID = "place_id"
        case isEnabled = "is_enabled"
        case targetPrice = "target_price"
    }
}

private struct PriceAlertEventRow: Identifiable, Decodable {
    let id: UUID
    let userID: UUID
    let placeID: UUID
    let reportID: UUID?
    let title: String
    let message: String
    let targetPrice: Int?
    let matchedPrice: Int
    let isRead: Bool
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case placeID = "place_id"
        case reportID = "report_id"
        case title
        case message
        case targetPrice = "target_price"
        case matchedPrice = "matched_price"
        case isRead = "is_read"
        case createdAt = "created_at"
    }

    var matchedPriceText: String {
        "\(matchedPrice.formatted())원"
    }

    var targetPriceText: String {
        guard let targetPrice else {
            return "목표가 없음"
        }
        return "\(targetPrice.formatted())원 이하"
    }

    var createdDateLabel: String {
        String(createdAt.prefix(10))
    }

    func markedRead() -> PriceAlertEventRow {
        PriceAlertEventRow(
            id: id,
            userID: userID,
            placeID: placeID,
            reportID: reportID,
            title: title,
            message: message,
            targetPrice: targetPrice,
            matchedPrice: matchedPrice,
            isRead: true,
            createdAt: createdAt
        )
    }
}

private struct PriceAlertEventReadRequest: Encodable {
    let targetEventID: UUID

    enum CodingKeys: String, CodingKey {
        case targetEventID = "target_event_id"
    }
}

private struct PriceAlertEventReadPatch: Encodable {
    let isRead: Bool

    enum CodingKeys: String, CodingKey {
        case isRead = "is_read"
    }
}

private enum ImagePrivacyProcessor {
    struct ProcessedImage {
        let data: Data
    }

    static func makeSafeJPEGData(from image: UIImage) throws -> ProcessedImage {
        let maxLength: CGFloat = 1600
        let originalSize = image.size
        let longestSide = max(originalSize.width, originalSize.height)
        let scale = longestSide > maxLength ? maxLength / longestSide : 1
        let targetSize = CGSize(
            width: max(1, floor(originalSize.width * scale)),
            height: max(1, floor(originalSize.height * scale))
        )

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true

        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let redrawnImage = renderer.image { _ in
            UIColor.white.setFill()
            UIBezierPath(rect: CGRect(origin: .zero, size: targetSize)).fill()
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }

        guard let data = redrawnImage.jpegData(compressionQuality: 0.78) else {
            throw SupabasePlacesError.invalidResponse
        }

        return ProcessedImage(data: data)
    }
}

// MARK: - Main Screens

private struct JjantechSearchBar: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Brand.gray500)

            TextField(placeholder, text: $text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.gray900)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)

            if text.isEmpty == false {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("검색어 지우기")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Brand.gray200, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.05), radius: 9, y: 4)
    }
}

private struct ExploreView: View {
    @EnvironmentObject private var placesViewModel: PlacesViewModel
    @EnvironmentObject private var authManager: AuthManager
    @StateObject private var locationManager = JjantechLocationManager.shared
    @State private var selectedCategory: PlaceCategory = .food
    @State private var selectedFilter = "1만원 이하"
    @State private var selectedSort = "추천순"
    @State private var searchText = ""

    private let filters = ["1만원 이하", "5천원 이하", "인증됨", "영업중"]
    private let sortOptions = ["추천순", "가격 낮은순", "거리순", "평점순"]

    private var filteredPlaces: [Place] {
        var result = placesViewModel.places.filter { $0.category == selectedCategory }

        if selectedFilter == "1만원 이하" {
            result = result.filter { $0.basePrice <= 10000 }
        }

        if selectedFilter == "5천원 이하" {
            result = result.filter { $0.basePrice <= 5000 }
        }

        if selectedFilter == "인증됨" {
            result = result.filter(\.isVerified)
        }

        if selectedFilter == "영업중" {
            result = result.filter { $0.statusText == "영업중" }
        }

        result = result.filter { $0.matchesSearch(searchText) }

        switch selectedSort {
        case "가격 낮은순":
            result = result.sorted { $0.basePrice < $1.basePrice }
        case "거리순":
            if let userCoord = locationManager.coordinate {
                result = result.sorted { $0.coordinate.distance(to: userCoord) < $1.coordinate.distance(to: userCoord) }
            } else {
                result = result.sorted { $0.distanceMeters < $1.distanceMeters }
            }
        case "평점순":
            result = result.sorted {
                if $0.rating == $1.rating {
                    return $0.reviewCount > $1.reviewCount
                }
                return $0.rating > $1.rating
            }
        default:
            result = result.sorted {
                if $0.isFeatured != $1.isFeatured {
                    return $0.isFeatured && !$1.isFeatured
                }
                if $0.trustScore != $1.trustScore {
                    return $0.trustScore > $1.trustScore
                }
                return $0.basePrice < $1.basePrice
            }
        }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            ExploreHeader(
                selectedCategory: $selectedCategory,
                locationStatus: locationManager.authorizationStatus,
                hasLiveLocation: locationManager.coordinate != nil,
                onRequestLocation: {
                    locationManager.requestPermissionAndStart()
                }
            )

            DataStatusBanner(viewModel: placesViewModel)

            JjantechSearchBar(
                text: $searchText,
                placeholder: "\(selectedCategory.title), 가게명, 메뉴명 검색"
            )
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Brand.gray50)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(filters, id: \.self) { filter in
                        Button {
                            selectedFilter = filter
                        } label: {
                            Text(filter)
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .foregroundStyle(selectedFilter == filter ? .white : Brand.gray700)
                                .background(selectedFilter == filter ? Brand.primary : Brand.gray100)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(selectedFilter == filter ? Brand.primary : Brand.gray200, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            .background(Brand.gray50)

            ExploreSortBar(
                resultCount: filteredPlaces.count,
                selectedSort: $selectedSort,
                sortOptions: sortOptions
            )
            .background(Brand.gray50)

            ScrollView {
                if filteredPlaces.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.title.weight(.bold))
                            .foregroundStyle(Brand.gray300)
                        Text("조건에 맞는 장소가 없어요")
                            .font(.subheadline.weight(.heavy))
                            .foregroundStyle(Brand.gray700)
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "다른 카테고리나 필터를 시도해보세요." : "검색어를 줄이거나 다른 메뉴명으로 찾아보세요.")
                            .font(.caption)
                            .foregroundStyle(Brand.gray500)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(spacing: 10) {
                        ChallengeExploreEntryCard(session: authManager.session)

                        ForEach(filteredPlaces) { place in
                            NavigationLink {
                                PlaceDetailView(place: place)
                            } label: {
                                PlaceCard(place: place)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 2)
                    .padding(.bottom, 18)
                }
            }
            .background(Brand.gray50)
        }
        .background(Brand.gray50)
        .onAppear {
            if locationManager.isAuthorized {
                locationManager.startUpdating()
            }
        }
    }
}

private struct ChallengeExploreEntryCard: View {
    let session: AuthSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Color(hex: "#78350F"))
                    .frame(width: 42, height: 42)
                    .background(Color(hex: "#FEF3C7"))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("1억 챌린지")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text("저렴한 장소를 이용할 때마다 절약액이 자산처럼 쌓여요.")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                        .lineSpacing(2)
                }

                Spacer()
            }

            HStack(spacing: 8) {
                Text("절약이 자산이 되는 순간")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Brand.price)
                Spacer()
                if let session {
                    NavigationLink {
                        ChallengeView(session: session)
                    } label: {
                        Text("내 기록 보기")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Brand.primary)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("MY에서 로그인")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Brand.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Brand.blue50)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(hex: "#FDE68A"), lineWidth: 1)
        )
    }
}

private struct ExploreSortBar: View {
    let resultCount: Int
    @Binding var selectedSort: String
    let sortOptions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("검색 결과 \(resultCount)곳")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Brand.gray700)

                Spacer()

                Label("정렬", systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Brand.gray500)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sortOptions, id: \.self) { option in
                        Button {
                            selectedSort = option
                        } label: {
                            Text(option)
                                .font(.caption.weight(.heavy))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .foregroundStyle(selectedSort == option ? .white : Brand.gray700)
                                .background(selectedSort == option ? Brand.gray900 : .white)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(selectedSort == option ? Brand.gray900 : Brand.gray200, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 10)
    }
}

enum MapZoomAction: Equatable {
    case zoomIn
    case zoomOut
}

private struct MapExploreView: View {
    private static let defaultMapFilters: Set<String> = ["1만원 이하"]
    private let filterOptions = ["1만원 이하", "영업중", "인증됨", "거리순"]

    @EnvironmentObject private var placesViewModel: PlacesViewModel
    @StateObject private var locationManager = JjantechLocationManager.shared
    @State private var selectedCategory: PlaceCategory = .food
    @State private var selectedPlaceID: UUID?
    @State private var shouldTrackLocation = false
    @State private var isBottomSheetExpanded = false
    @State private var isFilterPanelVisible = false
    @State private var selectedMapFilters: Set<String> = MapExploreView.defaultMapFilters
    @State private var draftMapFilters: Set<String> = MapExploreView.defaultMapFilters
    @State private var mapToast: String?
    @State private var mapSearchText = ""
    @State private var pendingZoomAction: MapZoomAction?
    @State private var pendingZoomNonce: Int = 0

    private var places: [Place] {
        placesViewModel.places
    }

    private var visiblePlaces: [Place] {
        var result = places.filter { $0.category == selectedCategory }

        if selectedMapFilters.contains("1만원 이하") {
            result = result.filter { $0.basePrice <= 10000 }
        }

        if selectedMapFilters.contains("영업중") {
            result = result.filter { $0.statusText == "영업중" }
        }

        if selectedMapFilters.contains("인증됨") {
            result = result.filter(\.isVerified)
        }

        if selectedMapFilters.contains("거리순") {
            if let userCoord = locationManager.coordinate {
                result = result.sorted {
                    $0.coordinate.distance(to: userCoord) < $1.coordinate.distance(to: userCoord)
                }
            } else {
                result = result.sorted { $0.distanceMeters < $1.distanceMeters }
            }
        }

        result = result.filter { $0.matchesSearch(mapSearchText) }

        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            MapHeader(
                selectedCategory: $selectedCategory,
                isListMode: isBottomSheetExpanded,
                onMapTap: {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        isBottomSheetExpanded = false
                    }
                    showToast("지도를 넓게 볼게요")
                },
                onListTap: {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        isBottomSheetExpanded = true
                    }
                    showToast("장소를 리스트로 정리했어요")
                }
            )

            DataStatusBanner(viewModel: placesViewModel)

            ZStack(alignment: .bottom) {
                NaverPriceMapView(
                    places: visiblePlaces,
                    selectedPlaceID: $selectedPlaceID,
                    shouldTrackLocation: $shouldTrackLocation,
                    isLocationAuthorized: locationManager.isAuthorized,
                    zoomAction: $pendingZoomAction,
                    zoomNonce: pendingZoomNonce
                )

                VStack {
                    JjantechSearchBar(
                        text: $mapSearchText,
                        placeholder: "지도에서 가게명, 메뉴명 검색"
                    )
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 6)

                    HStack(alignment: .top) {
                        Spacer()
                        MapLegend()
                            .padding(.top, 8)
                            .padding(.trailing, 12)
                    }

                    Spacer()
                }

                VStack {
                    Spacer()

                    HStack {
                        Spacer()

                        VStack(spacing: 10) {
                            VStack(spacing: 0) {
                                Button {
                                    triggerZoom(.zoomIn)
                                } label: {
                                    Image(systemName: "plus")
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(Brand.gray700)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)

                                Rectangle()
                                    .fill(Brand.gray200)
                                    .frame(width: 22, height: 1)

                                Button {
                                    triggerZoom(.zoomOut)
                                } label: {
                                    Image(systemName: "minus")
                                        .font(.headline.weight(.bold))
                                        .foregroundStyle(Brand.gray700)
                                        .frame(width: 44, height: 44)
                                }
                                .buttonStyle(.plain)
                            }
                            .background(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                            .shadow(color: .black.opacity(0.10), radius: 10, y: 4)

                            Button {
                                handleLocationButtonTap()
                            } label: {
                                Image(systemName: shouldTrackLocation ? "location.fill" : "location")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(shouldTrackLocation ? .white : Brand.primary)
                                    .frame(width: 44, height: 44)
                                    .background(shouldTrackLocation ? Brand.primary : .white)
                                    .clipShape(RoundedRectangle(cornerRadius: 13))
                                    .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                            }
                            .buttonStyle(.plain)

                            Button {
                                if isFilterPanelVisible {
                                    closeFilterPanel(apply: false)
                                } else {
                                    openFilterPanel()
                                }
                            } label: {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(isFilterPanelVisible ? .white : Brand.gray700)
                                    .frame(width: 44, height: 44)
                                    .background(isFilterPanelVisible ? Brand.gray900 : .white)
                                    .clipShape(RoundedRectangle(cornerRadius: 13))
                                    .shadow(color: .black.opacity(0.10), radius: 10, y: 4)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, isBottomSheetExpanded ? 438 : 202)
                    }
                }

                if isFilterPanelVisible {
                    MapFilterPanel(
                        options: filterOptions,
                        draftFilters: $draftMapFilters,
                        defaultFilters: MapExploreView.defaultMapFilters,
                        onApply: { closeFilterPanel(apply: true) },
                        onReset: { resetDraftFilters() },
                        onCancel: { closeFilterPanel(apply: false) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, isBottomSheetExpanded ? 438 : 202)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                if let mapToast {
                    VStack {
                        Text(mapToast)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                            .background(Brand.gray900.opacity(0.88))
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                            .padding(.top, 12)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                MapBottomSheet(
                    places: visiblePlaces,
                    selectedCategory: selectedCategory,
                    selectedPlaceID: $selectedPlaceID,
                    isExpanded: $isBottomSheetExpanded
                )
                .frame(height: isBottomSheetExpanded ? 420 : 184)
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: isBottomSheetExpanded)
            }
            .onChange(of: selectedCategory) { _, newValue in
                selectedPlaceID = places.first(where: { $0.category == newValue })?.id
                isBottomSheetExpanded = false
                if isFilterPanelVisible {
                    closeFilterPanel(apply: false)
                }
                showToast("\(newValue.title)만 보여드릴게요")
            }
            .onChange(of: selectedMapFilters) { _, _ in
                selectedPlaceID = visiblePlaces.first?.id
            }
            .onChange(of: mapSearchText) { _, _ in
                selectedPlaceID = visiblePlaces.first?.id
            }
            .onChange(of: locationManager.lastError) { _, newValue in
                if let newValue { showToast(newValue) }
            }
            .onChange(of: locationManager.authorizationStatus) { _, status in
                if status == .authorizedWhenInUse || status == .authorizedAlways {
                    locationManager.startUpdating()
                    if shouldTrackLocation == false {
                        shouldTrackLocation = true
                        showToast("내 위치를 실시간으로 따라가요")
                    }
                } else if status == .denied || status == .restricted {
                    shouldTrackLocation = false
                }
            }
            .onAppear {
                selectedPlaceID = visiblePlaces.first?.id
                switch locationManager.authorizationStatus {
                case .notDetermined:
                    locationManager.requestPermissionAndStart()
                case .authorizedWhenInUse, .authorizedAlways:
                    locationManager.startUpdating()
                default:
                    break
                }
            }
            .onDisappear {
                locationManager.stopUpdating()
            }
        }
        .background(Brand.gray50)
    }

    private func triggerZoom(_ action: MapZoomAction) {
        pendingZoomAction = action
        pendingZoomNonce &+= 1
    }

    private func handleLocationButtonTap() {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestPermissionAndStart()
            showToast("위치 권한을 요청하고 있어요")
        case .authorizedWhenInUse, .authorizedAlways:
            shouldTrackLocation.toggle()
            if shouldTrackLocation {
                locationManager.startUpdating()
                showToast("내 위치를 따라갑니다")
            } else {
                showToast("자유롭게 지도를 둘러볼 수 있어요")
            }
        case .denied, .restricted:
            showToast("설정 앱에서 위치 권한을 허용해주세요")
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        @unknown default:
            break
        }
    }

    private func openFilterPanel() {
        draftMapFilters = selectedMapFilters
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            isFilterPanelVisible = true
        }
        showToast("필터를 열었어요")
    }

    private func closeFilterPanel(apply: Bool) {
        if apply {
            selectedMapFilters = draftMapFilters
        } else {
            draftMapFilters = selectedMapFilters
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            isFilterPanelVisible = false
        }
        if apply {
            showToast("필터를 적용했어요")
        }
    }

    private func resetDraftFilters() {
        draftMapFilters = MapExploreView.defaultMapFilters
        showToast("필터를 기본값으로 되돌렸어요")
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            mapToast = message
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if mapToast == message {
                    mapToast = nil
                }
            }
        }
    }
}

#if canImport(NMapsMap)
private struct NaverPriceMapView: View {
    let places: [Place]
    @Binding var selectedPlaceID: UUID?
    @Binding var shouldTrackLocation: Bool
    let isLocationAuthorized: Bool
    @Binding var zoomAction: MapZoomAction?
    let zoomNonce: Int

    var body: some View {
        if NaverMapRuntime.hasConfiguredKey {
            RealNaverPriceMapView(
                places: places,
                selectedPlaceID: $selectedPlaceID,
                shouldTrackLocation: $shouldTrackLocation,
                isLocationAuthorized: isLocationAuthorized,
                zoomAction: $zoomAction,
                zoomNonce: zoomNonce
            )
        } else {
            NaverMapSetupRequiredView(places: places)
        }
    }
}

private struct RealNaverPriceMapView: UIViewRepresentable {
    let places: [Place]
    @Binding var selectedPlaceID: UUID?
    @Binding var shouldTrackLocation: Bool
    let isLocationAuthorized: Bool
    @Binding var zoomAction: MapZoomAction?
    let zoomNonce: Int

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> NMFNaverMapView {
        let naverMapView = NMFNaverMapView(frame: .zero)
        let mapView = naverMapView.mapView

        naverMapView.showCompass = true
        naverMapView.showScaleBar = true
        naverMapView.showLocationButton = false
        naverMapView.showZoomControls = false

        mapView.mapType = .basic
        mapView.isTiltGestureEnabled = false
        mapView.isRotateGestureEnabled = false
        mapView.isZoomGestureEnabled = true
        mapView.isScrollGestureEnabled = true
        mapView.minZoomLevel = 6
        mapView.maxZoomLevel = 20
        mapView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 168, right: 0)
        mapView.setLayerGroup(NMF_LAYER_GROUP_BUILDING, isEnabled: true)
        mapView.setLayerGroup(NMF_LAYER_GROUP_TRANSIT, isEnabled: true)

        // Detect user-driven camera moves so the follow-mode auto-disengages
        // when the user pans/zooms manually.
        mapView.addCameraDelegate(delegate: context.coordinator)

        let start = places.first?.naverLatLng ?? NMGLatLng(lat: 37.5498, lng: 126.9142)
        let camera = NMFCameraUpdate(scrollTo: start, zoomTo: 14.7)
        camera.animation = .easeIn
        mapView.moveCamera(camera)

        return naverMapView
    }

    func updateUIView(_ naverMapView: NMFNaverMapView, context: Context) {
        context.coordinator.sync(
            places: places,
            selectedPlaceID: selectedPlaceID,
            mapView: naverMapView.mapView,
            onSelect: { selectedPlaceID = $0 }
        )

        if let action = zoomAction, zoomNonce != context.coordinator.lastZoomNonce {
            context.coordinator.lastZoomNonce = zoomNonce
            let mapView = naverMapView.mapView
            let currentZoom = mapView.zoomLevel
            let target: Double
            switch action {
            case .zoomIn:
                target = min(currentZoom + 1, mapView.maxZoomLevel)
            case .zoomOut:
                target = max(currentZoom - 1, mapView.minZoomLevel)
            }
            let camera = NMFCameraUpdate(zoomTo: target)
            camera.animation = .easeOut
            camera.animationDuration = 0.25
            mapView.moveCamera(camera)
            DispatchQueue.main.async {
                if zoomAction == action {
                    zoomAction = nil
                }
            }
        }

        let previousTracking = context.coordinator.lastTracking
        let desiredMode: NMFMyPositionMode
        if !isLocationAuthorized {
            desiredMode = .disabled
        } else if shouldTrackLocation {
            desiredMode = .direction
        } else {
            desiredMode = .normal
        }
        context.coordinator.applyPositionMode(desiredMode, on: naverMapView.mapView)
        context.coordinator.lastTracking = shouldTrackLocation
        context.coordinator.onTrackingDisengaged = {
            if shouldTrackLocation {
                shouldTrackLocation = false
            }
        }

        if shouldTrackLocation {
            return
        }

        if previousTracking == true, shouldTrackLocation == false {
            return
        }

        if let selected = places.first(where: { $0.id == selectedPlaceID }),
           context.coordinator.lastCenteredID != selected.id {
            let camera = NMFCameraUpdate(scrollTo: selected.naverLatLng, zoomTo: 15.4)
            camera.animation = .easeIn
            naverMapView.mapView.moveCamera(camera)
            context.coordinator.lastCenteredID = selected.id
        } else if places.first(where: { $0.id == selectedPlaceID }) == nil,
                  let first = places.first {
            selectedPlaceID = first.id
        }
    }

    final class Coordinator: NSObject, NMFMapViewCameraDelegate {
        private var markers: [UUID: NMFMarker] = [:]
        private var appliedPositionMode: NMFMyPositionMode = .disabled
        var lastTracking: Bool = false
        var lastCenteredID: UUID?
        var lastZoomNonce: Int = 0
        var onTrackingDisengaged: (() -> Void)?

        func applyPositionMode(_ mode: NMFMyPositionMode, on mapView: NMFMapView) {
            guard mapView.positionMode != mode else {
                appliedPositionMode = mode
                return
            }
            mapView.positionMode = mode
            appliedPositionMode = mode
        }

        // User-driven gesture/scroll: drop the camera-follow mode (.direction)
        // back to .normal so the user can pan freely while the blue dot stays.
        func mapView(_ mapView: NMFMapView, cameraWillChangeByReason reason: Int, animated: Bool) {
            guard appliedPositionMode == .direction else { return }
            if reason == NMFMapChangedByGesture {
                mapView.positionMode = .normal
                appliedPositionMode = .normal
                DispatchQueue.main.async { [weak self] in
                    self?.onTrackingDisengaged?()
                }
            }
        }

        func sync(
            places: [Place],
            selectedPlaceID: UUID?,
            mapView: NMFMapView,
            onSelect: @escaping (UUID) -> Void
        ) {
            let currentIDs = Set(places.map(\.id))
            for (id, marker) in markers where !currentIDs.contains(id) {
                marker.mapView = nil
                markers[id] = nil
            }

            for place in places {
                let marker = markers[place.id] ?? NMFMarker()
                marker.position = place.naverLatLng
                marker.captionText = place.name
                marker.subCaptionText = "\(place.kind) · \(place.distanceTextShort)"
                marker.captionTextSize = 13
                marker.subCaptionTextSize = 11
                marker.captionColor = UIColor(hex: "#0F172A")
                marker.subCaptionColor = UIColor(hex: "#64748B")
                marker.iconImage = NMFOverlayImage(
                    image: PriceMarkerImageFactory.make(
                        price: place.priceText,
                        tint: place.category.markerUIColor,
                        selected: selectedPlaceID == place.id
                    )
                )
                marker.width = selectedPlaceID == place.id ? 96 : 86
                marker.height = selectedPlaceID == place.id ? 42 : 38
                marker.zIndex = selectedPlaceID == place.id ? 20 : 10
                marker.touchHandler = { _ in
                    onSelect(place.id)
                    return true
                }
                marker.mapView = mapView
                markers[place.id] = marker
            }
        }
    }
}

private enum NaverMapRuntime {
    static var hasConfiguredKey: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "NMFNcpKeyId") as? String else {
            return false
        }

        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "YOUR_NCP_KEY_ID_HERE"
    }
}

private enum PriceMarkerImageFactory {
    static func make(price: String, tint: UIColor, selected: Bool) -> UIImage {
        let size = CGSize(width: selected ? 112 : 100, height: selected ? 50 : 46)
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            let cg = context.cgContext
            let bubbleHeight: CGFloat = selected ? 36 : 32
            let bubbleRect = CGRect(x: 0, y: 0, width: size.width, height: bubbleHeight)
            let radius = bubbleHeight / 2

            cg.setShadow(offset: CGSize(width: 0, height: 4), blur: 8, color: tint.withAlphaComponent(0.28).cgColor)

            let bubblePath = UIBezierPath(roundedRect: bubbleRect, cornerRadius: radius)
            tint.setFill()
            bubblePath.fill()

            let tail = UIBezierPath()
            tail.move(to: CGPoint(x: size.width / 2 - 7, y: bubbleHeight - 1))
            tail.addLine(to: CGPoint(x: size.width / 2 + 7, y: bubbleHeight - 1))
            tail.addLine(to: CGPoint(x: size.width / 2, y: size.height - 4))
            tail.close()
            tint.setFill()
            tail.fill()

            cg.setShadow(offset: .zero, blur: 0, color: nil)

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: selected ? 14 : 13, weight: .heavy),
                .foregroundColor: UIColor.white,
                .paragraphStyle: paragraph
            ]

            let textRect = CGRect(x: 6, y: selected ? 8 : 7, width: size.width - 12, height: 18)
            price.draw(in: textRect, withAttributes: attributes)
        }
        .withRenderingMode(.alwaysOriginal)
    }
}

private extension Place {
    var naverLatLng: NMGLatLng {
        NMGLatLng(lat: coordinate.latitude, lng: coordinate.longitude)
    }
}
#else
private struct NaverPriceMapView: View {
    let places: [Place]
    @Binding var selectedPlaceID: UUID?
    @Binding var shouldTrackLocation: Bool
    let isLocationAuthorized: Bool
    @Binding var zoomAction: MapZoomAction?
    let zoomNonce: Int

    var body: some View {
        NaverMapSetupRequiredView(places: places)
    }
}
#endif

private struct NaverMapSetupRequiredView: View {
    let places: [Place]

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Brand.blue50, Color(hex: "#DBEAFE")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 14) {
                Image(systemName: "map.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(Brand.primary)
                    .frame(width: 78, height: 78)
                    .background(.white.opacity(0.85))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                VStack(spacing: 6) {
                    Text("네이버 지도 설정 필요")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text("NMapsMap 패키지와 NMFNcpKeyId가 준비되면 이 영역이 네이버 지도로 렌더링됩니다.")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("예정 마커 \(places.count)개")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Brand.primary700)
                    ForEach(places.prefix(3)) { place in
                        HStack {
                            Text(place.name)
                            Spacer()
                            Text(place.priceText)
                                .foregroundStyle(Brand.price)
                        }
                        .font(.caption.weight(.bold))
                    }
                }
                .padding(12)
                .background(.white.opacity(0.86))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(24)
        }
    }
}

private struct PlaceDetailView: View {
    let place: Place
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var favoritesViewModel: FavoritesViewModel
    @EnvironmentObject private var challengeViewModel: ChallengeViewModel
    @State private var selectedTab: PlaceDetailTab = .home
    @State private var detailToast: String?
    @State private var isShowingShareSheet = false
    @State private var isShowingVisitSavingSheet = false

    private let phoneNumber = "02-305-1906"
    private var isFavorited: Bool {
        favoritesViewModel.isFavorite(place)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Brand.gray900)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button {
                        guard let session = authManager.session else {
                            showDetailToast("로그인하면 즐겨찾기를 저장할 수 있어요")
                            return
                        }
                        Task {
                            let didFavorite = await favoritesViewModel.toggle(place: place, session: session)
                            showDetailToast(didFavorite ? "즐겨찾기에 추가했어요" : "즐겨찾기에서 뺐어요")
                        }
                    } label: {
                        Image(systemName: isFavorited ? "star.fill" : "star")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(isFavorited ? Brand.amber : Brand.gray300)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)

                    Button {
                        isShowingShareSheet = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Brand.gray900)
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(place.name)
                        .font(.largeTitle.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    HStack(spacing: 7) {
                        Text(place.kind)
                        Text("·")
                        Text("리뷰 \(place.reviewCount)")
                        Text("·")
                        Text("최저 \(place.priceText)")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.gray500)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        DetailActionButton(title: "출발", systemImage: "arrow.turn.up.right", style: .soft) {
                            openInMaps(asDestination: false)
                        }
                        DetailActionButton(title: "도착", systemImage: "location.fill", style: .primary) {
                            openInMaps(asDestination: true)
                        }
                        DetailActionButton(title: "공유", systemImage: "square.and.arrow.up", style: .outline) {
                            isShowingShareSheet = true
                        }
                        DetailActionButton(title: "전화", systemImage: "phone", style: .outline) {
                            callPhone()
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .padding(.bottom, 14)
            .background(.white)

            PlaceDetailTabBar(selectedTab: $selectedTab)

            TabView(selection: $selectedTab) {
                PlaceDetailHomePage(place: place)
                    .tag(PlaceDetailTab.home)

                PlaceDetailMenuPage(place: place)
                    .tag(PlaceDetailTab.menu)

                PlaceDetailReviewPage(place: place)
                    .tag(PlaceDetailTab.review)

                PlaceDetailPhotoPage(place: place)
                    .tag(PlaceDetailTab.photo)

                PlaceDetailNearbyPage(place: place)
                    .tag(PlaceDetailTab.nearby)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .highPriorityGesture(pageSwipeGesture)
            .animation(.easeInOut(duration: 0.2), value: selectedTab)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                NavigationLink {
                    PriceReportView(place: place)
                } label: {
                    Label("가격 제보", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.primary700)
                        .background(Brand.blue50)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                        .overlay(
                            RoundedRectangle(cornerRadius: 13)
                                .stroke(Brand.blue100, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    guard authManager.session != nil else {
                        showDetailToast("체험 모드로 절약액을 계산해볼게요")
                        isShowingVisitSavingSheet = true
                        return
                    }
                    isShowingVisitSavingSheet = true
                } label: {
                    Label("방문 완료", systemImage: "checkmark.seal.fill")
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .background(Brand.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 13))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(
                Color.white
                    .shadow(color: .black.opacity(0.08), radius: 10, y: -4)
            )
        }
        .background(Brand.gray50)
        .overlay(alignment: .top) {
            if let detailToast {
                Text(detailToast)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Brand.gray900.opacity(0.88))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $isShowingShareSheet) {
            ShareSheet(items: ["[짠테크] \(place.name) — \(place.kind) · 최저 \(place.priceText)\n\(place.address)"])
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $isShowingVisitSavingSheet) {
            if let session = authManager.session {
                VisitSavingSheet(place: place, session: session) { summary in
                    showDetailToast("이번 방문으로 \(summary.currentSavingsText)까지 모았어요")
                }
                .environmentObject(challengeViewModel)
                .presentationDetents([.large])
            } else {
                VisitSavingPreviewSheet(place: place)
                    .presentationDetents([.large])
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }

    private func callPhone() {
        let normalized = phoneNumber.replacingOccurrences(of: "-", with: "")
        guard let url = URL(string: "tel://\(normalized)"), UIApplication.shared.canOpenURL(url) else {
            showDetailToast("이 기기에서는 전화를 걸 수 없어요")
            return
        }
        UIApplication.shared.open(url)
    }

    private func openInMaps(asDestination: Bool) {
        let lat = place.coordinate.latitude
        let lng = place.coordinate.longitude
        let nameEncoded = place.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? place.name
        let appleMapsURL = "http://maps.apple.com/?ll=\(lat),\(lng)&q=\(nameEncoded)\(asDestination ? "&dirflg=w" : "")"
        if let url = URL(string: appleMapsURL) {
            UIApplication.shared.open(url)
        }
    }

    private func showDetailToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.18)) {
            detailToast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if detailToast == message {
                    detailToast = nil
                }
            }
        }
    }

    private var pageSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height

                guard abs(horizontal) > abs(vertical), abs(horizontal) > 55 else {
                    return
                }

                withAnimation(.easeInOut(duration: 0.22)) {
                    if horizontal < 0 {
                        selectedTab = selectedTab.next
                    } else {
                        selectedTab = selectedTab.previous
                    }
                }
            }
    }
}

private enum PlaceDetailTab: String, CaseIterable, Identifiable {
    case home = "홈"
    case menu = "메뉴"
    case review = "리뷰"
    case photo = "사진"
    case nearby = "주변"

    var id: Self { self }

    var next: PlaceDetailTab {
        guard let index = Self.allCases.firstIndex(of: self) else {
            return self
        }

        let nextIndex = min(index + 1, Self.allCases.count - 1)
        return Self.allCases[nextIndex]
    }

    var previous: PlaceDetailTab {
        guard let index = Self.allCases.firstIndex(of: self) else {
            return self
        }

        let previousIndex = max(index - 1, 0)
        return Self.allCases[previousIndex]
    }
}

private struct PlaceDetailTabBar: View {
    @Binding var selectedTab: PlaceDetailTab

    var body: some View {
        HStack(spacing: 0) {
            ForEach(PlaceDetailTab.allCases) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 9) {
                        Text(tab.rawValue)
                            .font(.headline.weight(selectedTab == tab ? .heavy : .semibold))
                            .foregroundStyle(selectedTab == tab ? Brand.gray900 : Brand.gray500)
                        Capsule()
                            .fill(selectedTab == tab ? Brand.gray900 : .clear)
                            .frame(width: 28, height: 3)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                    .padding(.bottom, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .background(.white)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Brand.gray200)
                .frame(height: 1)
        }
    }
}

private enum DetailActionStyle {
    case primary
    case soft
    case outline
}

private struct DetailActionButton: View {
    let title: String
    let systemImage: String
    let style: DetailActionStyle
    var action: () -> Void = {}

    private var foreground: Color {
        switch style {
        case .primary:
            return .white
        case .soft:
            return Brand.primary
        case .outline:
            return Brand.gray700
        }
    }

    private var background: Color {
        switch style {
        case .primary:
            return Brand.primary
        case .soft:
            return Brand.blue50
        case .outline:
            return .white
        }
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(foreground)
                .padding(.horizontal, 18)
                .frame(height: 46)
                .background(background)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(style == .outline ? Brand.gray200 : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct PlaceDetailHomePage: View {
    let place: Place
    @StateObject private var locationManager = JjantechLocationManager.shared
    @State private var copyToast: String?

    private var liveDistanceText: String {
        guard let userCoord = locationManager.coordinate else {
            return place.distanceTextShort
        }
        let meters = userCoord.distance(to: place.coordinate)
        if meters < 1000 {
            return "\(Int(meters))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                DetailPhotoStrip(place: place)

                DetailSection {
                    HStack(spacing: 12) {
                        Text("\(place.trustScore)")
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(Brand.primary)

                        VStack(alignment: .leading, spacing: 3) {
                            Text("가격 신뢰도")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(Brand.primary700)
                            Text("영수증 인증 \(place.receiptCount)건 · \(place.updatedText)")
                                .font(.caption)
                                .foregroundStyle(Brand.primary)
                        }

                        Spacer()

                        Text("인증됨")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Brand.price)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .padding(12)
                    .background(Brand.blue50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    HStack(spacing: 10) {
                        DetailMetric(value: liveDistanceText, label: "현재 거리")
                        DetailMetric(value: place.openTime, label: "영업 시작")
                        DetailMetric(value: place.statusText, label: "현재 상태", valueColor: Brand.price)
                    }
                    .padding(.top, 4)
                }

                DetailSection(title: "위치 정보") {
                    InfoLine(systemImage: "mappin.and.ellipse", text: place.address, actionText: "복사") {
                        UIPasteboard.general.string = place.address
                        showCopyToast("주소가 복사됐어요")
                    }
                    InfoLine(systemImage: "tram.fill", text: place.stationNote, actionText: "지도") {
                        let nameEncoded = place.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? place.name
                        if let url = URL(string: "http://maps.apple.com/?ll=\(place.coordinate.latitude),\(place.coordinate.longitude)&q=\(nameEncoded)") {
                            UIApplication.shared.open(url)
                        }
                    }
                    InfoLine(systemImage: "clock.fill", text: "영업시간 \(place.openTime) 시작 · \(place.statusText)", actionText: "")
                    InfoLine(systemImage: "phone.fill", text: "02-305-1906", actionText: "복사") {
                        UIPasteboard.general.string = "02-305-1906"
                        showCopyToast("전화번호가 복사됐어요")
                    }
                }

                DetailSection(title: "짠테크 AI 브리핑") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "sparkles")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Brand.primary)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("사용자 제보를 요약해 드립니다.")
                                .font(.subheadline.weight(.heavy))
                                .foregroundStyle(Brand.gray900)
                            Text("이 장소는 \(place.priceText)부터 시작하는 가성비 메뉴가 강점이에요. \(place.tip)")
                                .font(.subheadline)
                                .foregroundStyle(Brand.gray700)
                                .lineSpacing(3)
                        }
                    }
                }
            }
            .padding(14)
            .padding(.bottom, 78)
        }
        .background(Brand.gray50)
        .overlay(alignment: .top) {
            if let copyToast {
                Text(copyToast)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 9)
                    .background(Brand.gray900.opacity(0.88))
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    private func showCopyToast(_ message: String) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.easeInOut(duration: 0.18)) {
            copyToast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeInOut(duration: 0.2)) {
                if copyToast == message {
                    copyToast = nil
                }
            }
        }
    }
}

private struct PlaceDetailMenuPage: View {
    let place: Place

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                DetailSection(title: "메뉴 \(place.menus.count)") {
                    VStack(spacing: 0) {
                        ForEach(place.menus) { menu in
                            MenuPriceRow(menu: menu)
                        }
                    }
                }

                DetailSection(title: "가격 제보 팁") {
                    Text("메뉴판이나 영수증 사진을 올리면 가격 신뢰도가 올라가고, 검수 후 포인트가 지급됩니다.")
                        .font(.subheadline)
                        .foregroundStyle(Brand.gray700)
                        .lineSpacing(3)
                }
            }
            .padding(14)
            .padding(.bottom, 78)
        }
        .background(Brand.gray50)
    }
}

private struct PlaceDetailReviewPage: View {
    let place: Place

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                DetailSection(title: "방문자 리뷰") {
                    ReviewSnippet(rank: 1, name: "mapo_saver", text: "\(place.priceText)에 이 정도면 점심값 방어 성공이에요. 양도 적당하고 혼밥하기 편했습니다.")
                    ReviewSnippet(rank: 2, name: "짠테커 민지", text: "가격 제보 보고 갔는데 실제 가격도 같았어요. \(place.updatedText) 정보라 믿을 만합니다.")
                    ReviewSnippet(rank: 3, name: "오늘도 절약", text: place.tip)
                }

                DetailSection(title: "블로그 리뷰") {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(place.category.softColor)
                            .frame(width: 82, height: 82)
                            .overlay(Text(place.icon).font(.largeTitle))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("서울 \(place.kind) 가성비 맛집으로 저장")
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(Brand.gray900)
                            Text("방문자 \(place.reviewCount)명이 남긴 가격과 메뉴 후기를 모았어요.")
                                .font(.caption)
                                .foregroundStyle(Brand.gray500)
                                .lineSpacing(2)
                        }
                        Spacer()
                    }
                }
            }
            .padding(14)
            .padding(.bottom, 78)
        }
        .background(Brand.gray50)
    }
}

private struct PlaceDetailPhotoPage: View {
    let place: Place

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("방문자 사진·영수증")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Brand.gray900)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<9, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(index.isMultiple(of: 2) ? place.category.softColor : Brand.blue50)
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                VStack(spacing: 6) {
                                    Text(index.isMultiple(of: 3) ? "🧾" : place.icon)
                                        .font(.title)
                                    Text(index.isMultiple(of: 3) ? "영수증" : "메뉴")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(Brand.gray500)
                                }
                            )
                    }
                }
            }
            .padding(14)
            .padding(.bottom, 78)
        }
        .background(Brand.gray50)
    }
}

private struct PlaceDetailNearbyPage: View {
    let place: Place
    @EnvironmentObject private var placesViewModel: PlacesViewModel

    private var nearbyPlaces: [Place] {
        placesViewModel.places.filter { $0.id != place.id && $0.category == place.category }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("주변 \(place.category.title) 가성비 장소")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Brand.gray900)

                ForEach(nearbyPlaces) { nearby in
                    MiniNearbyRow(place: nearby)
                }
            }
            .padding(14)
            .padding(.bottom, 78)
        }
        .background(Brand.gray50)
    }
}

private struct DetailPhotoStrip: View {
    let place: Place

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 18)
                        .fill(index.isMultiple(of: 2) ? place.category.softColor : Brand.blue50)
                        .frame(width: index == 0 ? 260 : 150, height: 150)
                        .overlay(
                            VStack(spacing: 8) {
                                Text(place.icon)
                                    .font(.system(size: 44))
                                Text(index == 0 ? place.name : "방문자 사진")
                                    .font(.subheadline.weight(.heavy))
                                    .foregroundStyle(Brand.gray700)
                            }
                        )
                }
            }
        }
    }
}

private struct InfoLine: View {
    let systemImage: String
    let text: String
    let actionText: String
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Brand.gray300)
                .frame(width: 22)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(Brand.gray700)
                .lineSpacing(2)

            Spacer(minLength: 8)

            if let action {
                Button(action: action) {
                    Text(actionText)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
            } else {
                Text(actionText)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Brand.gray300)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ReviewSnippet: View {
    let rank: Int
    let name: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(rank)")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Brand.primary)
                .frame(width: 24, height: 24)
                .background(Brand.blue50)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Brand.gray900)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(Brand.gray700)
                    .lineSpacing(3)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct MiniNearbyRow: View {
    let place: Place

    var body: some View {
        HStack(spacing: 12) {
            Text(place.icon)
                .font(.title2)
                .frame(width: 54, height: 54)
                .background(place.category.softColor)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(place.name)
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Brand.gray900)
                Text("\(place.kind) · \(place.distanceTextShort) · ★ \(place.ratingText)")
                    .font(.caption)
                    .foregroundStyle(Brand.gray500)
            }

            Spacer()

            Text(place.priceText)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Brand.price)
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

private struct PriceReportView: View {
    let place: Place

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var authManager: AuthManager
    private let reportRepository = PriceReportRepository()
    @State private var menuName = ""
    @State private var price = ""
    @State private var visitDate = Date()
    @State private var memo = ""
    @State private var didSubmit = false
    @State private var isSubmitting = false

    @State private var pickedImages: [UIImage] = []
    @State private var photoSelections: [PhotosPickerItem] = []
    @State private var isShowingSourceDialog = false
    @State private var isShowingCamera = false
    @State private var isShowingPhotosPicker = false
    @State private var validationMessage: String?
    @State private var isCameraUnavailable = false

    private var sanitizedPrice: Int? {
        let digits = price.filter(\.isNumber)
        guard !digits.isEmpty, let value = Int(digits), value > 0 else { return nil }
        return value
    }

    private var canSubmit: Bool {
        sanitizedPrice != nil && !menuName.trimmingCharacters(in: .whitespaces).isEmpty && !pickedImages.isEmpty
    }

    private static let visitDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ko_KR")
        f.dateFormat = "yyyy년 M월 d일 (EEE)"
        return f
    }()

    private static let payloadDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Label(place.name, systemImage: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("가격 제보하기")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(.white)
                    Text("영수증 사진 인증 시 포인트 지급!")
                        .font(.caption)
                        .foregroundStyle(Brand.blue100)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 18)
            .background(Brand.primary.ignoresSafeArea(edges: .top))

            ScrollView {
                VStack(spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("이번 제보 예상 포인트")
                                .font(.caption)
                                .foregroundStyle(Brand.blue100)
                            Text(authManager.isSignedIn ? "+30P 획득 예정" : "로그인 시 포인트 연결")
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Image(systemName: "gift.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    }
                    .padding(14)
                    .background(Brand.primary600)
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    if !authManager.isSignedIn {
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "person.crop.circle.badge.exclamationmark")
                                .foregroundStyle(Brand.amber)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("로그인하면 제보 내역과 포인트를 연결할 수 있어요.")
                                    .font(.caption.weight(.heavy))
                                    .foregroundStyle(Brand.gray900)
                                Text("지금 제출하면 익명 제보로 저장되며 포인트는 지급되지 않아요.")
                                    .font(.caption2)
                                    .foregroundStyle(Brand.gray500)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(Color(hex: "#FFFBEB"))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color(hex: "#FDE68A"), lineWidth: 1)
                        )
                    }

                    FormCard(title: "메뉴 정보") {
                        StyledTextField(title: "메뉴명", text: $menuName)
                        StyledTextField(title: "가격", text: $price, suffix: "원")
                            .keyboardType(.numberPad)
                    }

                    FormCard(title: "인증 사진 첨부") {
                        VStack(spacing: 10) {
                            Button {
                                isShowingSourceDialog = true
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: "camera.fill")
                                        .font(.title2)
                                        .foregroundStyle(Brand.primary)
                                    Text("영수증 또는 메뉴판 추가")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(Brand.primary)
                                    Text(pickedImages.isEmpty ? "카메라 촬영 또는 앨범에서 선택 · 최대 4장" : "추가 사진을 더 올릴 수 있어요")
                                        .font(.caption)
                                        .foregroundStyle(Brand.gray500)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 22)
                                .background(Brand.blue50)
                                .clipShape(RoundedRectangle(cornerRadius: 13))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 13)
                                        .stroke(Brand.blue100, style: StrokeStyle(lineWidth: 2, dash: [6]))
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(pickedImages.count >= 4)
                            .opacity(pickedImages.count >= 4 ? 0.45 : 1)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(Array(pickedImages.enumerated()), id: \.offset) { index, image in
                                        PhotoThumb(image: image) {
                                            pickedImages.remove(at: index)
                                        }
                                    }
                                    if pickedImages.count < 4 {
                                        Button {
                                            isShowingSourceDialog = true
                                        } label: {
                                            PhotoThumb(systemImage: "plus", isDashed: true)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }

                            Text(pickedImages.isEmpty ? "최소 1장의 영수증 또는 메뉴판 사진을 첨부해야 제보할 수 있어요." : "총 \(pickedImages.count)장 첨부됨")
                                .font(.caption2)
                                .foregroundStyle(pickedImages.isEmpty ? Brand.red : Brand.gray500)
                        }
                    }

                    FormCard(title: "방문 정보") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("방문 날짜")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(Brand.gray500)
                            DatePicker(
                                "방문 날짜",
                                selection: $visitDate,
                                in: ...Date(),
                                displayedComponents: .date
                            )
                            .datePickerStyle(.compact)
                            .labelsHidden()
                            .environment(\.locale, Locale(identifier: "ko_KR"))
                        }
                        StyledTextField(title: "메모", text: $memo)
                    }

                    if let validationMessage {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Brand.red)
                            Text(validationMessage)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Brand.red)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(hex: "#FEF2F2"))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(14)
            }
            .background(Brand.gray50)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                Task {
                    await submit()
                }
            } label: {
                HStack(spacing: 8) {
                    if isSubmitting {
                        ProgressView()
                            .tint(.white)
                    }
                    Label(
                        isSubmitting ? "제보 저장 중" : (canSubmit ? (authManager.isSignedIn ? "제보 제출하고 30P 받기" : "익명 제보 제출하기") : "필수 항목을 입력해주세요"),
                        systemImage: "paperplane.fill"
                    )
                }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.white)
                    .background(canSubmit && !isSubmitting ? Brand.primary : Brand.gray300)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(.white)
        }
        .confirmationDialog("사진 첨부", isPresented: $isShowingSourceDialog, titleVisibility: .visible) {
            Button("카메라로 촬영") {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    isShowingCamera = true
                } else {
                    isCameraUnavailable = true
                }
            }
            Button("앨범에서 선택") {
                isShowingPhotosPicker = true
            }
            Button("취소", role: .cancel) {}
        }
        .sheet(isPresented: $isShowingCamera) {
            CameraImagePicker(source: .camera) { image in
                appendImage(image)
            }
            .ignoresSafeArea()
        }
        .photosPicker(
            isPresented: $isShowingPhotosPicker,
            selection: $photoSelections,
            maxSelectionCount: max(1, 4 - pickedImages.count),
            matching: .images
        )
        .onChange(of: photoSelections) { _, items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        await MainActor.run { appendImage(image) }
                    }
                }
                await MainActor.run { photoSelections.removeAll() }
            }
        }
        .alert("카메라를 사용할 수 없어요", isPresented: $isCameraUnavailable) {
            Button("확인", role: .cancel) {}
        } message: {
            Text("이 기기에서는 카메라를 사용할 수 없어 앨범 첨부만 가능해요.")
        }
        .alert("제보가 접수됐어요", isPresented: $didSubmit) {
            Button("확인") {
                dismiss()
            }
        } message: {
            if authManager.isSignedIn {
                Text("검수 완료 후 30P가 지급됩니다.")
            } else {
                Text("익명 제보로 접수됐어요. 포인트를 받으려면 로그인 후 제보해주세요.")
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }

    private func appendImage(_ image: UIImage) {
        guard pickedImages.count < 4 else { return }
        pickedImages.append(image)
        validationMessage = nil
    }

    private func submit() async {
        let trimmedMenu = menuName.trimmingCharacters(in: .whitespaces)
        if trimmedMenu.isEmpty {
            validationMessage = "메뉴명을 입력해주세요."
            return
        }
        guard let sanitizedPrice else {
            validationMessage = "가격은 1원 이상의 숫자로 입력해주세요."
            return
        }
        guard !pickedImages.isEmpty else {
            validationMessage = "영수증 또는 메뉴판 사진을 1장 이상 첨부해주세요."
            return
        }
        validationMessage = nil

        let trimmedMemo = memo.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = PriceReportDraft(
            id: UUID(),
            userID: authManager.session?.userID,
            placeID: place.id,
            menuName: trimmedMenu,
            reportedPrice: sanitizedPrice,
            visitDate: Self.payloadDateFormatter.string(from: visitDate),
            memo: trimmedMemo.isEmpty ? nil : trimmedMemo,
            photoCount: pickedImages.count,
            hasPhotoAttachment: true,
            reportStatus: "pending",
            rewardPoints: 30,
            uploadStatus: "pending_upload"
        )

        isSubmitting = true
        defer { isSubmitting = false }

        do {
            try await reportRepository.submit(draft, images: pickedImages, session: authManager.session)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            didSubmit = true
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            validationMessage = priceReportErrorMessage(for: error)
            print("가격 제보 저장 실패:", error.localizedDescription)
        }
    }

    private func priceReportErrorMessage(for error: Error) -> String {
        let message = error.localizedDescription
        if message.contains("같은 장소의 같은 메뉴") {
            return "같은 장소의 같은 메뉴는 24시간 안에 한 번만 제보할 수 있어요."
        }
        if message.contains("최대 10건") {
            return "24시간 안에는 최대 10건까지만 가격 제보할 수 있어요."
        }
        if message.contains("방금 접수") {
            return "같은 가격 제보가 방금 접수됐어요. 잠시 후 다시 시도해주세요."
        }
        if message.contains("update_price_report_upload_status") || message.contains("PGRST202") {
            return "제보 저장 준비 중 문제가 있어요. 잠시 후 다시 시도해주세요."
        }
        if message.contains("row-level security") || message.contains("violates row-level") {
            return "지금은 제보를 저장할 수 없어요. 잠시 후 다시 시도해주세요."
        }
        return "제보 저장에 실패했어요. 네트워크 상태를 확인하고 다시 시도해주세요."
    }
}

private struct MyPageView: View {
    @EnvironmentObject private var authManager: AuthManager
    @EnvironmentObject private var placesViewModel: PlacesViewModel
    @EnvironmentObject private var favoritesViewModel: FavoritesViewModel
    @EnvironmentObject private var challengeViewModel: ChallengeViewModel
    @StateObject private var profileViewModel = ProfileViewModel()
    @StateObject private var pointTransactionsViewModel = PointTransactionsViewModel()
    @StateObject private var priceAlertSettingsViewModel = PriceAlertSettingsViewModel()
    @StateObject private var priceAlertEventsViewModel = PriceAlertEventsViewModel()
    @StateObject private var reportsViewModel = MyReportsViewModel()
    @StateObject private var adminReviewViewModel = AdminReviewViewModel()
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = "짠테커"
    @State private var isSignUpMode = false
    @State private var guestChallengeSummary = GuestChallengeStore.previewSummary()
    @State private var guestChallengeLogs = GuestChallengeStore.previewLogs()
    @State private var isImportingGuestChallenge = false
    @State private var guestChallengeImportMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Circle()
                    .fill(.white.opacity(0.18))
                    .frame(width: 62, height: 62)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                    )
                    .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 2))

                VStack(alignment: .leading, spacing: 3) {
                    Text(authManager.isSignedIn ? profileViewModel.displayNameText : "로그인이 필요해요")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(.white)
                    Text(authManager.isSignedIn ? (authManager.session?.email ?? "Supabase Auth로 연결된 짠테커") : "제보 내역과 포인트를 연결하려면 로그인해주세요")
                        .font(.caption)
                        .foregroundStyle(Brand.blue100)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("보유 포인트")
                            .font(.caption)
                            .foregroundStyle(Brand.blue100)
                        Text(authManager.isSignedIn ? profileViewModel.pointBalanceText : "-")
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text(authManager.isSignedIn ? "Member" : "Guest")
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .foregroundStyle(Color(hex: "#78350F"))
                        .background(Color(hex: "#FBBF24"))
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                }
                .padding(14)
                .background(.white.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.18), lineWidth: 1)
                )
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.primary700.ignoresSafeArea(edges: .top))

            ScrollView {
                VStack(spacing: 12) {
                    if !authManager.isSignedIn {
                        AuthFormCard(
                            email: $email,
                            password: $password,
                            displayName: $displayName,
                            isSignUpMode: $isSignUpMode,
                            isLoading: authManager.isLoading,
                            message: authManager.authMessage,
                            onSubmit: {
                                Task {
                                    if isSignUpMode {
                                        await authManager.signUp(email: email, password: password, displayName: displayName)
                                    } else {
                                        await authManager.signIn(email: email, password: password)
                                    }
                                }
                            },
                            onPasswordReset: {
                                Task {
                                    await authManager.sendPasswordReset(email: email)
                                }
                            },
                            onDiagnose: {
                                Task {
                                    await authManager.diagnoseAndSignIn(email: email, password: password)
                                }
                            }
                        )
                    } else {
                        HStack(spacing: 10) {
                            Button {
                                authManager.signOut()
                                profileViewModel.reset()
                                pointTransactionsViewModel.reset()
                                challengeViewModel.reset()
                                priceAlertSettingsViewModel.reset()
                                priceAlertEventsViewModel.reset()
                                reportsViewModel.reset()
                                adminReviewViewModel.reset()
                            } label: {
                                Label("로그아웃", systemImage: "rectangle.portrait.and.arrow.right")
                                    .font(.subheadline.weight(.heavy))
                                    .foregroundStyle(Brand.red)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 44)
                                    .background(Color(hex: "#FEF2F2"))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 10) {
                        StatBox(number: authManager.isSignedIn ? "\(reportsViewModel.totalCount)" : "-", label: "내 제보")
                        StatBox(number: authManager.isSignedIn ? profileViewModel.acceptedReportCountText : "-", label: "승인")
                        StatBox(number: authManager.isSignedIn ? profileViewModel.pointBalanceText : "-", label: "보유 포인트")
                    }

                    PointTransactionsCard(
                        isSignedIn: authManager.isSignedIn,
                        isLoading: pointTransactionsViewModel.isLoading,
                        message: pointTransactionsViewModel.message,
                        transactions: pointTransactionsViewModel.transactions,
                        onRefresh: {
                            guard let session = authManager.session else { return }
                            Task {
                                await profileViewModel.loadProfile(session: session)
                                await pointTransactionsViewModel.loadTransactions(session: session)
                            }
                        }
                    )

                    ChallengeSummaryCard(
                        isSignedIn: authManager.isSignedIn,
                        isLoading: challengeViewModel.isLoading,
                        summary: challengeViewModel.summary,
                        message: challengeViewModel.message,
                        session: authManager.session,
                        onRefresh: {
                            guard let session = authManager.session else { return }
                            Task {
                                await challengeViewModel.load(session: session)
                            }
                        }
                    )

                    GuestChallengeLedgerCard(
                        isSignedIn: authManager.isSignedIn,
                        summary: guestChallengeSummary,
                        logs: guestChallengeLogs,
                        isImporting: isImportingGuestChallenge,
                        importMessage: guestChallengeImportMessage,
                        onClear: {
                            GuestChallengeStore.clear()
                            guestChallengeImportMessage = nil
                            refreshGuestChallenge()
                        },
                        onImport: {
                            guard let session = authManager.session else {
                                guestChallengeImportMessage = "로그인 후 실제 장부로 옮길 수 있어요."
                                return
                            }
                            Task {
                                await importGuestChallengeLogs(session: session)
                            }
                        }
                    )

                    if AppEnvironment.showsInternalTools {
                        ChallengeQAChecklistCard(isSignedIn: authManager.isSignedIn)

                        OperationsQABoardCard(isSignedIn: authManager.isSignedIn)

                        SystemStatusCard(
                            isSignedIn: authManager.isSignedIn,
                            authEmail: authManager.session?.email,
                            placesCount: placesViewModel.places.count,
                            isUsingFallback: placesViewModel.isUsingFallback,
                            placesStatusMessage: placesViewModel.statusMessage,
                            guestLogCount: guestChallengeLogs.count,
                            reportCount: reportsViewModel.totalCount,
                            pointBalanceText: profileViewModel.pointBalanceText,
                            challengeSummary: challengeViewModel.summary,
                            onRefreshPlaces: {
                                Task {
                                    await placesViewModel.loadPlaces()
                                }
                            }
                        )
                    }

                    FavoritePlacesCard(
                        isSignedIn: authManager.isSignedIn,
                        isLoading: favoritesViewModel.isLoading,
                        message: favoritesViewModel.message,
                        places: favoritePlaces,
                        onRefresh: {
                            guard let session = authManager.session else { return }
                            Task {
                                await favoritesViewModel.loadFavorites(session: session)
                            }
                        }
                    )

                    PriceAlertSettingsCard(
                        isSignedIn: authManager.isSignedIn,
                        isLoading: priceAlertSettingsViewModel.isLoading,
                        isSaving: priceAlertSettingsViewModel.isSaving,
                        message: priceAlertSettingsViewModel.message,
                        favoritePlaces: favoritePlaces,
                        viewModel: priceAlertSettingsViewModel,
                        session: authManager.session,
                        onRefresh: {
                            guard let session = authManager.session else { return }
                            Task {
                                await priceAlertSettingsViewModel.loadSettings(session: session)
                            }
                        }
                    )

                    PriceAlertEventsCard(
                        isSignedIn: authManager.isSignedIn,
                        isLoading: priceAlertEventsViewModel.isLoading,
                        isSaving: priceAlertEventsViewModel.isSaving,
                        message: priceAlertEventsViewModel.message,
                        events: priceAlertEventsViewModel.events,
                        unreadCount: priceAlertEventsViewModel.unreadCount,
                        session: authManager.session,
                        onRefresh: {
                            guard let session = authManager.session else { return }
                            Task {
                                await priceAlertEventsViewModel.loadEvents(session: session)
                            }
                        },
                        onMarkAsRead: { event, session in
                            Task {
                                await priceAlertEventsViewModel.markAsRead(event, session: session)
                            }
                        }
                    )

                    if authManager.isSignedIn, let message = profileViewModel.message {
                        Text(message)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.gray500)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 2)
                    }

                    if authManager.isSignedIn {
                        AdminReviewCard(
                            viewModel: adminReviewViewModel,
                            session: authManager.session
                        )
                    }

                    MyReportsCard(
                        isSignedIn: authManager.isSignedIn,
                        isLoading: reportsViewModel.isLoading,
                        message: reportsViewModel.message,
                        reports: reportsViewModel.reports,
                        onRefresh: {
                            guard let session = authManager.session else { return }
                            Task {
                                await profileViewModel.loadProfile(session: session)
                                await pointTransactionsViewModel.loadTransactions(session: session)
                                await challengeViewModel.load(session: session)
                                await reportsViewModel.loadReports(session: session)
                            }
                        }
                    )

                    MonthlySavingsReportCard(
                        isSignedIn: authManager.isSignedIn,
                        summary: challengeViewModel.summary,
                        logs: challengeViewModel.logs
                    )

                    VStack(spacing: 0) {
                        MyMenuRow(icon: "camera.fill", title: "제보 내역", subtitle: authManager.isSignedIn ? "MY 상단에서 최근 제보 확인 가능" : "로그인 후 확인 가능", badge: "+30P", iconColor: Brand.primary)
                        MyMenuRow(icon: "gift.fill", title: "포인트 사용 내역", subtitle: authManager.isSignedIn ? "최근 포인트 장부를 MY 상단에서 확인 가능" : "로그인 후 확인 가능", iconColor: Brand.amber)
                        MyMenuRow(icon: "bell.fill", title: "알림 설정", subtitle: authManager.isSignedIn ? "즐겨찾기 가격 알림을 MY 상단에서 관리" : "로그인 후 확인 가능", iconColor: Brand.price)
                        MyMenuRow(icon: "gearshape.fill", title: "계정 설정", subtitle: "개인정보 · 위치권한", iconColor: Brand.red)
                    }
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.gray200, lineWidth: 1)
                    )
                }
                .padding(14)
                .padding(.bottom, 12)
            }
            .background(Brand.gray50)
        }
        .background(Brand.gray50)
        .onAppear {
            refreshGuestChallenge()
            guard let session = authManager.session else { return }
            Task {
                await challengeViewModel.load(session: session)
            }
        }
        .task(id: authManager.session?.userID) {
            guard let session = authManager.session else {
                profileViewModel.reset()
                pointTransactionsViewModel.reset()
                challengeViewModel.reset()
                priceAlertSettingsViewModel.reset()
                priceAlertEventsViewModel.reset()
                reportsViewModel.reset()
                adminReviewViewModel.reset()
                return
            }
            await profileViewModel.loadProfile(session: session)
            await pointTransactionsViewModel.loadTransactions(session: session)
            await challengeViewModel.load(session: session)
            await priceAlertSettingsViewModel.loadSettings(session: session)
            await priceAlertEventsViewModel.loadEvents(session: session)
            await reportsViewModel.loadReports(session: session)
            await adminReviewViewModel.loadIfAdmin(session: session)
        }
    }

    private var favoritePlaces: [Place] {
        placesViewModel.places.filter { favoritesViewModel.favoritePlaceIDs.contains($0.id) }
    }

    private func refreshGuestChallenge() {
        guestChallengeSummary = GuestChallengeStore.previewSummary()
        guestChallengeLogs = GuestChallengeStore.previewLogs()
    }

    private func importGuestChallengeLogs(session: AuthSession) async {
        let logs = GuestChallengeStore.loadLogs()
        guard logs.isEmpty == false else {
            guestChallengeImportMessage = "옮길 체험 기록이 없어요."
            refreshGuestChallenge()
            return
        }

        isImportingGuestChallenge = true
        guestChallengeImportMessage = nil
        defer { isImportingGuestChallenge = false }

        let repository = ChallengeRepository()
        var importedCount = 0
        var remainingLogs: [GuestSavingLog] = []

        for log in logs {
            guard let placeID = log.placeID, log.savedAmount > 0 else {
                remainingLogs.append(log)
                continue
            }

            let request = SavingLogRequest(
                placeID: placeID,
                menuID: log.menuID,
                placeName: log.placeName,
                menuName: log.menuName,
                savedAmount: log.savedAmount,
                originalPrice: log.originalPrice,
                actualPrice: log.actualPrice,
                category: log.category,
                source: "guest_import"
            )

            do {
                _ = try await repository.logSaving(request, session: session)
                importedCount += 1
            } catch {
                remainingLogs.append(log)
            }
        }

        GuestChallengeStore.replace(with: remainingLogs)
        refreshGuestChallenge()
        await challengeViewModel.load(session: session)

        if importedCount > 0, remainingLogs.isEmpty {
            guestChallengeImportMessage = "\(importedCount)개 체험 기록을 실제 1억 챌린지에 반영했어요."
        } else if importedCount > 0 {
            guestChallengeImportMessage = "\(importedCount)개를 반영했고, \(remainingLogs.count)개는 다시 시도할 수 있어요."
        } else {
            guestChallengeImportMessage = "체험 기록을 옮기지 못했어요. 잠시 후 다시 시도해주세요."
        }
    }
}

private struct V2EmptyView: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("짠테크")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white)
                    Text("맵")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer()
                }
                Text(title)
                    .font(.largeTitle.weight(.heavy))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 18)
            .background(accent.ignoresSafeArea(edges: .top))

            Spacer()

            VStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(accent)
                    .frame(width: 84, height: 84)
                    .background(accent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 22))

                VStack(spacing: 6) {
                    Text("\(title) v2 준비 중")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Brand.gray500)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 28)

            Spacer()
        }
        .background(Brand.gray50)
    }
}

// MARK: - Shared UI

private struct MonthlySavingsReportCard: View {
    let isSignedIn: Bool
    let summary: ChallengeSummary?
    let logs: [SavingsLogRow]

    private var currentMonthPrefix: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "yyyy-MM"
        return formatter.string(from: Date())
    }

    private var monthlyLogs: [SavingsLogRow] {
        logs.filter { $0.createdAt.hasPrefix(currentMonthPrefix) }
    }

    private var totalText: String {
        guard isSignedIn else { return "로그인 후 확인" }
        let total = summary?.monthlySavings ?? monthlyLogs.reduce(0) { $0 + $1.savedAmount }
        return "+\(total.formatted())원"
    }

    private var categoryItems: [(title: String, amount: Int, color: Color)] {
        let grouped = Dictionary(grouping: monthlyLogs, by: \.category)
            .mapValues { rows in rows.reduce(0) { $0 + $1.savedAmount } }

        return [
            ("식당", grouped["food"] ?? 0, Brand.primary),
            ("카페", grouped["cafe"] ?? 0, Brand.purple),
            ("미용실", grouped["hair"] ?? 0, Brand.price),
            ("숙박", grouped["lodging"] ?? 0, Brand.amber)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("이달의 절약 리포트")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Brand.primary700)
                    Text(totalText)
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(isSignedIn ? Brand.price : Brand.gray500)
                }

                Spacer()

                Text("\(monthlyLogs.count)회 기록")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Brand.gray500)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 9))
            }

            if !isSignedIn {
                Text("로그인하면 방문 완료로 쌓인 절약액을 월별로 볼 수 있어요.")
                    .font(.caption)
                    .foregroundStyle(Brand.gray500)
                    .lineSpacing(2)
            } else if monthlyLogs.isEmpty {
                Text("이번 달 절약 기록이 아직 없어요. 장소 상세에서 방문 완료를 눌러 첫 기록을 남겨보세요.")
                    .font(.caption)
                    .foregroundStyle(Brand.gray500)
                    .lineSpacing(2)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(categoryItems, id: \.title) { item in
                    SavingBox(
                        title: item.title,
                        amount: isSignedIn ? "+\(item.amount.formatted())원" : "-",
                        color: item.color
                    )
                }
            }
        }
        .padding(14)
        .background(Brand.blue50)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Brand.blue100, lineWidth: 1)
        )
    }
}

private struct AdminReviewCard: View {
    @ObservedObject var viewModel: AdminReviewViewModel
    let session: AuthSession?
    @State private var selectedReport: MyPriceReportRow?

    private var visibleReports: [MyPriceReportRow] {
        Array(viewModel.pendingReports.prefix(5))
    }

    private var visiblePipelineIssues: [ReportPipelineAuditRow] {
        Array(viewModel.pipelineAudits.filter { !$0.isOK }.prefix(4))
    }

    var body: some View {
        Group {
            if viewModel.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Brand.primary)
                    Text("운영자 권한 확인 중")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                    Spacer()
                }
                .padding(14)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Brand.gray200, lineWidth: 1)
                )
            } else if viewModel.isAdmin {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("운영자 검수")
                                .font(.headline.weight(.heavy))
                                .foregroundStyle(Brand.gray900)
                            Text("검수 대기 \(viewModel.pendingCount)건")
                                .font(.caption)
                                .foregroundStyle(Brand.gray500)
                        }

                        Spacer()

                        Button {
                            guard let session else { return }
                            Task {
                                await viewModel.loadIfAdmin(session: session)
                            }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.subheadline.weight(.heavy))
                                .foregroundStyle(Brand.primary)
                                .frame(width: 36, height: 36)
                                .background(Brand.blue50)
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.isSubmitting)
                    }

                    if let message = viewModel.message {
                        Text(message)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(message.contains("실패") ? Brand.red : Brand.price)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    if visibleReports.isEmpty {
                        MyReportsEmptyState(
                            icon: "checkmark.seal.fill",
                            title: "검수 대기 없음",
                            subtitle: "새 가격 제보가 접수되면 이곳에 표시됩니다."
                        )
                    } else {
                        VStack(spacing: 10) {
                            ForEach(visibleReports) { report in
                                Button {
                                    selectedReport = report
                                } label: {
                                    AdminPendingReportRow(report: report)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Divider()
                        .background(Brand.gray200)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("승인 파이프라인 QA")
                                    .font(.subheadline.weight(.heavy))
                                    .foregroundStyle(Brand.gray900)
                                Text("가격표 · 포인트 · 알림 · 챌린지 연결 상태")
                                    .font(.caption)
                                    .foregroundStyle(Brand.gray500)
                            }

                            Spacer()

                            Text(viewModel.pipelineIssueCount == 0 ? "정상" : "\(viewModel.pipelineIssueCount)건 확인")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(viewModel.pipelineIssueCount == 0 ? Brand.price : Brand.red)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background((viewModel.pipelineIssueCount == 0 ? Brand.price : Brand.red).opacity(0.10))
                                .clipShape(RoundedRectangle(cornerRadius: 9))
                        }

                        if viewModel.pipelineAudits.isEmpty {
                            MyReportsEmptyState(
                                icon: "list.bullet.clipboard.fill",
                                title: "승인 제보 없음",
                                subtitle: "승인된 제보가 생기면 연결 상태를 자동 점검합니다."
                            )
                        } else if visiblePipelineIssues.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.title3.weight(.heavy))
                                    .foregroundStyle(Brand.price)
                                Text("최근 승인 제보 파이프라인이 정상입니다.")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(Brand.gray700)
                                Spacer()
                            }
                            .padding(12)
                            .background(Brand.gray50)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        } else {
                            VStack(spacing: 8) {
                                ForEach(visiblePipelineIssues) { row in
                                    AdminPipelineAuditRowView(
                                        row: row,
                                        isSubmitting: viewModel.isSubmitting,
                                        onRepair: {
                                            guard let session else { return }
                                            Task {
                                                await viewModel.repairPipeline(row: row, session: session)
                                            }
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Brand.primary.opacity(0.22), lineWidth: 1)
                )
                .sheet(item: $selectedReport) { report in
                    AdminReviewDetailView(
                        report: report,
                        session: session,
                        isSubmitting: viewModel.isSubmitting,
                        onApprove: { note in
                            guard let session else { return }
                            Task {
                                await viewModel.approve(report: report, note: note, session: session)
                                selectedReport = nil
                            }
                        },
                        onReject: { reason, note in
                            guard let session else { return }
                            Task {
                                await viewModel.reject(report: report, reason: reason, note: note, session: session)
                                selectedReport = nil
                            }
                        }
                    )
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                }
            }
        }
    }
}

private struct AdminPendingReportRow: View {
    let report: MyPriceReportRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "doc.badge.clock")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Brand.primary)
                .frame(width: 36, height: 36)
                .background(Brand.blue50)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(report.menuName)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(report.reportedPrice.formatted())원")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.price)
                }

                HStack(spacing: 6) {
                    Text(report.createdDateLabel)
                    Text("·")
                    Text(report.photoLabel)
                    Text("·")
                    Text(report.userID?.uuidString.prefix(8).description ?? "익명")
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(Brand.gray500)

                if let memo = report.memo, !memo.isEmpty {
                    Text(memo)
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                        .lineLimit(2)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Brand.gray300)
                .padding(.top, 4)
        }
        .padding(12)
        .background(Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Brand.gray200, lineWidth: 1)
        )
    }
}

private struct AdminPipelineAuditRowView: View {
    let row: ReportPipelineAuditRow
    let isSubmitting: Bool
    let onRepair: () -> Void
    @State private var isShowingRepairConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(row.statusColor)
                    .frame(width: 32, height: 32)
                    .background(row.statusColor.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.statusText)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(row.statusColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                        Spacer()

                        Text(row.reportStatus)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Brand.gray500)
                    }

                    Text(row.summaryText)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text("예상 절약 \(row.expectedSavedAmount.formatted())원")
                        Text("알림 \(row.alertEventCount)건")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.gray500)
                }
            }

            Button {
                isShowingRepairConfirm = true
            } label: {
                Label(isSubmitting ? "복구 중" : "이 항목 복구", systemImage: "wrench.and.screwdriver.fill")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(isSubmitting ? Brand.gray300 : Brand.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting)
        }
        .padding(12)
        .background(Color(hex: "#FEF2F2").opacity(row.isOK ? 0 : 1))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(row.statusColor.opacity(0.20), lineWidth: 1)
        )
        .alert("파이프라인을 복구할까요?", isPresented: $isShowingRepairConfirm) {
            Button("취소", role: .cancel) {}
            Button("복구 실행") {
                onRepair()
            }
        } message: {
            Text("\(row.summaryText)의 가격표, 포인트, 알림, 챌린지 연결을 다시 맞춥니다.")
        }
    }
}

private struct AdminReviewDetailView: View {
    let report: MyPriceReportRow
    let session: AuthSession?
    let isSubmitting: Bool
    let onApprove: (String) -> Void
    let onReject: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    private let repository = AdminReviewRepository()
    @State private var approveNote = "영수증 가격과 메뉴명이 확인되어 승인합니다."
    @State private var rejectionReason = ""
    @State private var rejectionNote = "사용자에게 선명한 사진 재제보를 안내합니다."
    @State private var validationMessage: String?
    @State private var attachments: [ReportPhotoAttachment] = []
    @State private var isLoadingPhotos = false
    @State private var photoMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.menuName)
                            .font(.title3.weight(.heavy))
                            .foregroundStyle(Brand.gray900)
                        Text("\(report.reportedPrice.formatted())원")
                            .font(.title.weight(.heavy))
                            .foregroundStyle(Brand.price)
                        Text("제보자: \(report.userID?.uuidString ?? "익명 제보")")
                            .font(.caption)
                            .foregroundStyle(Brand.gray500)
                    }
                    .padding(16)
                    .background(Brand.blue50)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.blue100, lineWidth: 1)
                    )

                    VStack(spacing: 10) {
                        ReportDetailInfoRow(icon: "calendar", title: "방문일", value: report.visitDateLabel)
                        ReportDetailInfoRow(icon: "tray.and.arrow.up.fill", title: "등록일", value: report.createdDateLabel)
                        ReportDetailInfoRow(icon: "photo.on.rectangle.angled", title: "첨부", value: report.photoLabel)
                        ReportDetailInfoRow(icon: "gift.fill", title: "지급 포인트", value: "+\(report.rewardPoints)P")
                    }
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.gray200, lineWidth: 1)
                    )

                    AdminPhotoAttachmentsView(
                        isLoading: isLoadingPhotos,
                        message: photoMessage,
                        attachments: attachments,
                        onReload: {
                            Task {
                                await loadPhotos()
                            }
                        }
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("사용자 메모")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)
                        Text((report.memo?.isEmpty == false ? report.memo : "남긴 메모가 없어요.") ?? "남긴 메모가 없어요.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.gray700)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Brand.gray50)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.gray200, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("승인 메모")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)
                        StyledTextField(title: "승인 메모", text: $approveNote)
                        Button {
                            onApprove(approveNote)
                        } label: {
                            Label(isSubmitting ? "승인 중" : "승인하고 포인트 지급", systemImage: "checkmark.seal.fill")
                                .font(.subheadline.weight(.heavy))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(isSubmitting ? Brand.gray300 : Brand.price)
                                .clipShape(RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                    }
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.gray200, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("반려 처리")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)
                        StyledTextField(title: "반려 사유", text: $rejectionReason)
                        StyledTextField(title: "운영자 메모", text: $rejectionNote)

                        if let validationMessage {
                            Text(validationMessage)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Brand.red)
                        }

                        Button {
                            let trimmedReason = rejectionReason.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmedReason.isEmpty else {
                                validationMessage = "반려 사유를 입력해야 합니다."
                                return
                            }
                            validationMessage = nil
                            onReject(trimmedReason, rejectionNote)
                        } label: {
                            Label(isSubmitting ? "반려 중" : "반려 처리", systemImage: "xmark.seal.fill")
                                .font(.subheadline.weight(.heavy))
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .frame(height: 46)
                                .background(isSubmitting ? Brand.gray300 : Brand.red)
                                .clipShape(RoundedRectangle(cornerRadius: 13))
                        }
                        .buttonStyle(.plain)
                        .disabled(isSubmitting)
                    }
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.gray200, lineWidth: 1)
                    )
                }
                .padding(14)
            }
            .background(Brand.gray50)
            .navigationTitle("제보 검수")
            .navigationBarTitleDisplayMode(.inline)
            .task {
                await loadPhotos()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.bold))
                }
            }
        }
    }

    private func loadPhotos() async {
        guard let session else {
            photoMessage = "로그인 세션이 없어 사진을 불러올 수 없어요."
            return
        }
        isLoadingPhotos = true
        photoMessage = nil
        defer { isLoadingPhotos = false }

        do {
            attachments = try await repository.fetchPhotoAttachments(reportID: report.id, session: session)
            if attachments.isEmpty {
                photoMessage = "첨부 사진이 없어요."
            }
        } catch {
            photoMessage = "사진을 불러오지 못했어요. 010번 Supabase SQL 실행 여부를 확인해주세요."
            print("운영자 사진 조회 실패:", error.localizedDescription)
        }
    }
}

private struct AdminPhotoAttachmentsView: View {
    let isLoading: Bool
    let message: String?
    let attachments: [ReportPhotoAttachment]
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("인증 사진")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Brand.gray900)
                Spacer()
                Button(action: onReload) {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Brand.primary)
                        .frame(width: 30, height: 30)
                        .background(Brand.blue50)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Brand.primary)
                    Text("사진 불러오는 중")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.gray50)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if attachments.isEmpty {
                MyReportsEmptyState(
                    icon: "photo.on.rectangle.angled",
                    title: "사진 없음",
                    subtitle: message ?? "첨부된 사진을 찾지 못했어요."
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(attachments) { attachment in
                            AdminPhotoThumbnail(attachment: attachment)
                        }
                    }
                }
            }

            if let message, !attachments.isEmpty {
                Text(message)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(message.contains("못했") ? Brand.red : Brand.gray500)
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

private struct AdminPhotoThumbnail: View {
    let attachment: ReportPhotoAttachment
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                AsyncImage(url: attachment.signedURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(Brand.primary)
                            .frame(width: 132, height: 132)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(width: 132, height: 132)
                            .clipped()
                    case .failure:
                        Image(systemName: "photo.fill")
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(Brand.gray300)
                            .frame(width: 132, height: 132)
                            .background(Brand.gray100)
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(width: 132, height: 132)
                .background(Brand.gray100)
                .clipShape(RoundedRectangle(cornerRadius: 14))

                Text("사진 \(attachment.row.displayOrder + 1) · \(attachment.row.fileSizeLabel)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Brand.gray500)
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $isPresented) {
            AdminPhotoPreviewView(attachment: attachment)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct AdminPhotoPreviewView: View {
    let attachment: ReportPhotoAttachment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Brand.gray900.ignoresSafeArea()
                AsyncImage(url: attachment.signedURL) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .tint(.white)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(12)
                    case .failure:
                        VStack(spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.title.weight(.heavy))
                                .foregroundStyle(Brand.amber)
                            Text("사진을 불러오지 못했어요.")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            .navigationTitle("인증 사진")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                }
            }
        }
    }
}

private struct GuestChallengeLedgerCard: View {
    let isSignedIn: Bool
    let summary: ChallengeSummary?
    let logs: [SavingsLogRow]
    let isImporting: Bool
    let importMessage: String?
    let onClear: () -> Void
    let onImport: () -> Void

    var body: some View {
        if let summary, logs.isEmpty == false {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "tray.full.fill")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Brand.price)
                        .frame(width: 38, height: 38)
                        .background(Brand.green50)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("체험 장부")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)

                        Text(isSignedIn ? "로그인 상태지만 체험 기록은 아직 DB에 저장되지 않았어요." : "로그인 전 저장한 임시 절약 기록이에요.")
                            .font(.caption)
                            .foregroundStyle(Brand.gray500)
                    }

                    Spacer()
                }

                HStack(spacing: 10) {
                    GuestChallengeMetric(title: "체험 절약액", value: summary.currentSavingsText, color: Brand.price)
                    GuestChallengeMetric(title: "기록", value: "\(logs.count)건", color: Brand.primary)
                }

                VStack(alignment: .leading, spacing: 7) {
                    ForEach(logs.prefix(3)) { log in
                        HStack(spacing: 8) {
                            Text(log.iconText)

                            Text(log.titleText)
                                .lineLimit(1)

                            Spacer()

                            Text(log.savedAmountText)
                                .foregroundStyle(Brand.price)
                        }
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.gray700)
                    }
                }
                .padding(12)
                .background(Brand.gray50)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let importMessage {
                    Text(importMessage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 8) {
                    NavigationLink {
                        ChallengePreviewView()
                    } label: {
                        Text("체험 화면 보기")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Brand.primary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(Brand.blue50)
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)

                    if isSignedIn {
                        Button(action: onImport) {
                            Text(isImporting ? "이동 중" : "실제 장부로")
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(.white)
                                .frame(width: 88, height: 36)
                                .background(isImporting ? Brand.gray300 : Brand.primary)
                                .clipShape(RoundedRectangle(cornerRadius: 11))
                        }
                        .buttonStyle(.plain)
                        .disabled(isImporting)
                    }

                    Button(action: onClear) {
                        Text("비우기")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Brand.red)
                            .frame(width: 78, height: 36)
                            .background(Color(hex: "#FEF2F2"))
                            .clipShape(RoundedRectangle(cornerRadius: 11))
                    }
                    .buttonStyle(.plain)
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
}

private struct GuestChallengeMetric: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Brand.gray500)

            Text(value)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct FavoritePlacesCard: View {
    let isSignedIn: Bool
    let isLoading: Bool
    let message: String?
    let places: [Place]
    let onRefresh: () -> Void

    private var recentPlaces: [Place] {
        Array(places.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("즐겨찾기")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text(isSignedIn ? "다시 찾고 싶은 절약 장소를 모아둬요" : "로그인하면 관심 가게를 저장할 수 있어요")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                Spacer()

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(isSignedIn ? Brand.primary : Brand.gray300)
                        .frame(width: 36, height: 36)
                        .background(isSignedIn ? Brand.blue50 : Brand.gray100)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isSignedIn || isLoading)
            }

            if !isSignedIn {
                MyReportsEmptyState(
                    icon: "star.fill",
                    title: "로그인이 필요해요",
                    subtitle: "장소 상세에서 별 버튼을 누르면 관심 가게가 여기에 저장됩니다."
                )
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Brand.primary)
                    Text("즐겨찾기를 불러오는 중")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Brand.gray50)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if places.isEmpty {
                MyReportsEmptyState(
                    icon: "star",
                    title: "아직 저장한 장소가 없어요",
                    subtitle: message ?? "지도에서 가게 상세를 열고 별 버튼을 눌러보세요."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(recentPlaces) { place in
                        NavigationLink {
                            PlaceDetailView(place: place)
                        } label: {
                            FavoritePlaceRowView(place: place)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if places.count > recentPlaces.count {
                    Text("최근 5곳만 표시 중 · 전체 즐겨찾기 화면은 다음 단계에서 확장")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.gray500)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct PriceAlertSettingsCard: View {
    let isSignedIn: Bool
    let isLoading: Bool
    let isSaving: Bool
    let message: String?
    let favoritePlaces: [Place]
    @ObservedObject var viewModel: PriceAlertSettingsViewModel
    let session: AuthSession?
    let onRefresh: () -> Void

    private var recentPlaces: [Place] {
        Array(favoritePlaces.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("가격 알림")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text(isSignedIn ? "즐겨찾기 장소의 목표 가격을 관리해요" : "로그인 후 가격 알림을 설정할 수 있어요")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                Spacer()

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(isSignedIn ? Brand.primary : Brand.gray300)
                        .frame(width: 36, height: 36)
                        .background(isSignedIn ? Brand.blue50 : Brand.gray100)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isSignedIn || isLoading || isSaving)
            }

            if !isSignedIn {
                MyReportsEmptyState(
                    icon: "bell.slash.fill",
                    title: "로그인이 필요해요",
                    subtitle: "즐겨찾기와 가격 알림은 계정에 안전하게 저장됩니다."
                )
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Brand.primary)
                    Text("가격 알림 설정을 불러오는 중")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Brand.gray50)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if favoritePlaces.isEmpty {
                MyReportsEmptyState(
                    icon: "star",
                    title: "즐겨찾기한 장소가 필요해요",
                    subtitle: "장소 상세에서 별 버튼을 누른 뒤 가격 알림을 설정할 수 있습니다."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(recentPlaces) { place in
                        PriceAlertSettingRowView(
                            place: place,
                            isEnabled: viewModel.isEnabled(for: place),
                            targetPriceText: viewModel.targetPriceText(for: place),
                            isSaving: isSaving,
                            onToggle: {
                                guard let session else { return }
                                Task {
                                    await viewModel.toggle(place: place, session: session)
                                }
                            },
                            onUseCurrentPrice: {
                                guard let session else { return }
                                Task {
                                    await viewModel.setTargetToCurrentPrice(place: place, session: session)
                                }
                            },
                            onLowerTarget: {
                                guard let session else { return }
                                Task {
                                    await viewModel.lowerTargetPrice(place: place, session: session)
                                }
                            }
                        )
                    }
                }

                if favoritePlaces.count > recentPlaces.count {
                    Text("최근 5곳만 표시 중 · 전체 알림 화면은 다음 단계에서 확장")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.gray500)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let message {
                    Text(message)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(message.contains("실패") || message.contains("못했") ? Brand.red : Brand.price)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct PriceAlertEventsCard: View {
    let isSignedIn: Bool
    let isLoading: Bool
    let isSaving: Bool
    let message: String?
    let events: [PriceAlertEventRow]
    let unreadCount: Int
    let session: AuthSession?
    let onRefresh: () -> Void
    let onMarkAsRead: (PriceAlertEventRow, AuthSession) -> Void

    private var recentEvents: [PriceAlertEventRow] {
        Array(events.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("가격 알림함")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)
                        if unreadCount > 0 {
                            Text("\(unreadCount)")
                                .font(.caption2.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Brand.red)
                                .clipShape(Capsule())
                        }
                    }
                    Text(isSignedIn ? "목표 가격에 맞은 승인 제보를 확인해요" : "로그인 후 가격 알림을 확인할 수 있어요")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                Spacer()

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(isSignedIn ? Brand.primary : Brand.gray300)
                        .frame(width: 36, height: 36)
                        .background(isSignedIn ? Brand.blue50 : Brand.gray100)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isSignedIn || isLoading || isSaving)
            }

            if !isSignedIn {
                MyReportsEmptyState(
                    icon: "bell.badge.fill",
                    title: "로그인이 필요해요",
                    subtitle: "목표 가격 알림은 계정별로 안전하게 저장됩니다."
                )
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Brand.primary)
                    Text("가격 알림함을 불러오는 중")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Brand.gray50)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if events.isEmpty {
                MyReportsEmptyState(
                    icon: "bell",
                    title: "아직 가격 알림이 없어요",
                    subtitle: message ?? "즐겨찾기 가격 알림을 켜두면 조건에 맞는 승인 제보가 이곳에 표시됩니다."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(recentEvents) { event in
                        PriceAlertEventRowView(
                            event: event,
                            isSaving: isSaving,
                            onMarkAsRead: {
                                guard let session else { return }
                                onMarkAsRead(event, session)
                            }
                        )
                    }
                }

                if events.count > recentEvents.count {
                    Text("최근 5건만 표시 중 · 전체 알림함은 다음 단계에서 확장")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.gray500)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let message {
                    Text(message)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(message.contains("실패") || message.contains("못했") ? Brand.red : Brand.price)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct PriceAlertEventRowView: View {
    let event: PriceAlertEventRow
    let isSaving: Bool
    let onMarkAsRead: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.isRead ? "bell" : "bell.badge.fill")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(event.isRead ? Brand.gray500 : Brand.red)
                .frame(width: 34, height: 34)
                .background((event.isRead ? Brand.gray500 : Brand.red).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(event.title)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(event.matchedPriceText)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.price)
                        .lineLimit(1)
                }

                Text(event.message)
                    .font(.caption)
                    .foregroundStyle(Brand.gray500)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    Text(event.isRead ? "읽음" : "새 알림")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(event.isRead ? Brand.gray500 : Brand.red)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(event.targetPriceText)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Brand.gray500)

                    Text(event.createdDateLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                }
            }

            if !event.isRead {
                Button(action: onMarkAsRead) {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Brand.primary)
                        .frame(width: 28, height: 28)
                        .background(Brand.blue50)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
        .padding(12)
        .background(event.isRead ? Brand.gray50 : Color(hex: "#FFF7ED"))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(event.isRead ? Brand.gray200 : Color(hex: "#FDBA74"), lineWidth: 1)
        )
    }
}

private struct PriceAlertSettingRowView: View {
    let place: Place
    let isEnabled: Bool
    let targetPriceText: String
    let isSaving: Bool
    let onToggle: () -> Void
    let onUseCurrentPrice: () -> Void
    let onLowerTarget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: isEnabled ? "bell.fill" : "bell.slash.fill")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(isEnabled ? Brand.price : Brand.gray500)
                    .frame(width: 34, height: 34)
                    .background((isEnabled ? Brand.price : Brand.gray500).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    Text(place.name)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                        .lineLimit(1)
                    Text("현재 최저 \(place.priceText) · \(targetPriceText)")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onToggle) {
                    Text(isEnabled ? "ON" : "OFF")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(isEnabled ? .white : Brand.gray500)
                        .frame(width: 48, height: 30)
                        .background(isEnabled ? Brand.price : Brand.gray100)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }

            HStack(spacing: 8) {
                Button(action: onUseCurrentPrice) {
                    Label("현재가", systemImage: "scope")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Brand.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Brand.blue50)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)

                Button(action: onLowerTarget) {
                    Label("500원 낮춤", systemImage: "arrow.down")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Brand.price)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(Brand.green50)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(isSaving)
            }
        }
        .padding(12)
        .background(Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isEnabled ? Brand.price.opacity(0.35) : Brand.gray200, lineWidth: 1)
        )
    }
}

private struct ChallengeQAChecklistCard: View {
    let isSignedIn: Bool

    private var checklistItems: [(String, String)] {
        if isSignedIn {
            return [
                ("1", "지도 또는 탐색에서 아무 장소나 눌러 상세 화면으로 이동"),
                ("2", "하단의 방문 완료 버튼을 누르고 메뉴 선택"),
                ("3", "절약 기록 후 MY의 1억 챌린지 카드 증가 확인"),
                ("4", "1억 챌린지 상세에서 최근 기록과 취소 확인")
            ]
        }

        return [
            ("1", "Supabase Authentication에서 테스트 유저 생성"),
            ("2", "이메일 Confirm 처리 또는 Email confirm 옵션 확인"),
            ("3", "MY 탭에서 테스트 계정으로 로그인"),
            ("4", "로그인 후 방문 완료 테스트 진행")
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checklist.checked")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Brand.primary)
                    .frame(width: 38, height: 38)
                    .background(Brand.blue50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("1억 챌린지 테스트")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text(isSignedIn ? "시뮬레이터에서 핵심 루프를 순서대로 확인해요." : "먼저 로그인 테스트가 필요해요.")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                Spacer()
            }

            VStack(spacing: 8) {
                ForEach(checklistItems, id: \.0) { number, text in
                    HStack(alignment: .top, spacing: 9) {
                        Text(number)
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(isSignedIn ? Brand.primary : Brand.gray300)
                            .clipShape(Circle())

                        Text(text)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.gray700)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
            .background(Brand.gray50)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Brand.blue100, lineWidth: 1)
        )
    }
}

private struct OperationsQABoardCard: View {
    let isSignedIn: Bool

    @AppStorage("jjantechmap.qa.auth") private var didCheckAuth = false
    @AppStorage("jjantechmap.qa.visit") private var didCheckVisitSaving = false
    @AppStorage("jjantechmap.qa.report") private var didCheckPriceReport = false
    @AppStorage("jjantechmap.qa.admin") private var didCheckAdminApproval = false
    @AppStorage("jjantechmap.qa.reward") private var didCheckRewardPipeline = false

    private var completedCount: Int {
        [didCheckAuth, didCheckVisitSaving, didCheckPriceReport, didCheckAdminApproval, didCheckRewardPipeline]
            .filter { $0 }
            .count
    }

    private var progressText: String {
        "\(completedCount)/5 완료"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "clipboard.badge.checkmark.fill")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(Brand.price)
                    .frame(width: 38, height: 38)
                    .background(Brand.green50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("운영 QA 보드")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)

                        Text(progressText)
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(completedCount == 5 ? Brand.price : Brand.primary)
                            .clipShape(Capsule())
                    }

                    Text(isSignedIn ? "출시 전 핵심 데이터 흐름을 순서대로 검수해요." : "로그인 전에는 체크리스트를 미리 볼 수 있어요.")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                Spacer()
            }

            VStack(spacing: 9) {
                OperationsQACheckRow(
                    title: "로그인/세션 복원",
                    subtitle: "앱 재실행 후에도 MY가 로그인 상태인지 확인",
                    isOn: $didCheckAuth,
                    isEnabled: isSignedIn
                )
                OperationsQACheckRow(
                    title: "방문 완료 → 1억 챌린지",
                    subtitle: "장소 상세에서 절약 기록 후 MY와 챌린지 카드 증가 확인",
                    isOn: $didCheckVisitSaving,
                    isEnabled: isSignedIn
                )
                OperationsQACheckRow(
                    title: "가격 제보 + 사진 업로드",
                    subtitle: "영수증/인증사진 첨부 후 pending 제보 생성 확인",
                    isOn: $didCheckPriceReport,
                    isEnabled: isSignedIn
                )
                OperationsQACheckRow(
                    title: "운영자 승인/반려",
                    subtitle: "승인 시 가격표 반영, 반려 시 사용자 안내 확인",
                    isOn: $didCheckAdminApproval,
                    isEnabled: isSignedIn
                )
                OperationsQACheckRow(
                    title: "포인트/알림/챌린지 연결",
                    subtitle: "승인 후 포인트 장부, 가격 알림, 절약 로그 정합성 확인",
                    isOn: $didCheckRewardPipeline,
                    isEnabled: isSignedIn
                )
            }

            if !isSignedIn {
                Text("먼저 Supabase QA 계정 로그인을 성공시킨 뒤 체크를 진행해주세요.")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Brand.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(hex: "#FEF2F2"))
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }

            Button {
                didCheckAuth = false
                didCheckVisitSaving = false
                didCheckPriceReport = false
                didCheckAdminApproval = false
                didCheckRewardPipeline = false
            } label: {
                Text("QA 체크 초기화")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Brand.gray500)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(Brand.gray50)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(completedCount == 0)
            .opacity(completedCount == 0 ? 0.55 : 1)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Brand.green50, lineWidth: 1)
        )
    }
}

private struct OperationsQACheckRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    let isEnabled: Bool

    var body: some View {
        Button {
            guard isEnabled else { return }
            isOn.toggle()
            UINotificationFeedbackGenerator().notificationOccurred(isOn ? .success : .warning)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(isOn ? Brand.price : Brand.gray300)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(isEnabled ? Brand.gray900 : Brand.gray500)

                    Text(subtitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.gray500)
                        .lineSpacing(1)
                }

                Spacer()
            }
            .padding(11)
            .background(isOn ? Brand.green50 : Brand.gray50)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isOn ? Brand.price.opacity(0.22) : Brand.gray200, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

private struct SystemStatusCard: View {
    let isSignedIn: Bool
    let authEmail: String?
    let placesCount: Int
    let isUsingFallback: Bool
    let placesStatusMessage: String
    let guestLogCount: Int
    let reportCount: Int
    let pointBalanceText: String
    let challengeSummary: ChallengeSummary?
    let onRefreshPlaces: () -> Void

    private var supabaseConfigStatus: String {
        SupabaseConfig.current == nil ? "설정 없음" : "설정됨"
    }

    private var authStatusText: String {
        isSignedIn ? (authEmail ?? "로그인됨") : "로그인 전"
    }

    private var dataSourceText: String {
        isUsingFallback ? "목업 폴백" : "Supabase DB"
    }

    private var challengeStatusText: String {
        guard let challengeSummary else {
            return isSignedIn ? "불러오기 전" : "로그인 필요"
        }
        return challengeSummary.currentSavingsText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "waveform.path.ecg.rectangle.fill")
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(isUsingFallback ? Brand.amber : Brand.price)
                    .frame(width: 38, height: 38)
                    .background(isUsingFallback ? Color(hex: "#FFFBEB") : Brand.green50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text("시스템 상태")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text("로그인, DB 연결, 챌린지 데이터를 분리해서 확인해요.")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                Spacer()

                Button(action: onRefreshPlaces) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.primary)
                        .frame(width: 34, height: 34)
                        .background(Brand.blue50)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 8) {
                SystemStatusRow(
                    title: "Supabase 설정",
                    value: supabaseConfigStatus,
                    color: SupabaseConfig.current == nil ? Brand.red : Brand.price
                )
                SystemStatusRow(
                    title: "Auth 상태",
                    value: authStatusText,
                    color: isSignedIn ? Brand.price : Brand.amber
                )
                SystemStatusRow(
                    title: "장소 데이터",
                    value: "\(dataSourceText) · \(placesCount)곳",
                    color: isUsingFallback ? Brand.amber : Brand.price
                )
                SystemStatusRow(
                    title: "DB 메시지",
                    value: placesStatusMessage,
                    color: isUsingFallback ? Brand.amber : Brand.price
                )
                SystemStatusRow(
                    title: "게스트 체험 기록",
                    value: "\(guestLogCount)건",
                    color: guestLogCount > 0 ? Brand.primary : Brand.gray500
                )
                SystemStatusRow(
                    title: "내 제보/포인트",
                    value: isSignedIn ? "\(reportCount)건 · \(pointBalanceText)" : "로그인 필요",
                    color: isSignedIn ? Brand.primary : Brand.gray500
                )
                SystemStatusRow(
                    title: "1억 챌린지",
                    value: challengeStatusText,
                    color: challengeSummary == nil ? Brand.gray500 : Brand.price
                )
            }
            .padding(12)
            .background(Brand.gray50)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(isUsingFallback ? "DB 연결이 실패해도 앱은 목업 데이터로 계속 동작합니다. 출시 전에는 이 상태가 Supabase DB로 바뀌어야 합니다." : "장소 데이터가 Supabase DB에서 표시되고 있습니다.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isUsingFallback ? Brand.amber : Brand.price)
                .lineSpacing(2)
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isUsingFallback ? Color(hex: "#FDE68A") : Brand.green50, lineWidth: 1)
        )
    }
}

private struct SystemStatusRow: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(Brand.gray500)
                .frame(width: 92, alignment: .leading)

            Text(value)
                .font(.caption.weight(.heavy))
                .foregroundStyle(color)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct FavoritePlaceRowView: View {
    let place: Place

    var body: some View {
        HStack(spacing: 10) {
            Text(place.icon)
                .font(.title3)
                .frame(width: 38, height: 38)
                .background(place.category.softColor)
                .clipShape(RoundedRectangle(cornerRadius: 11))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(place.name)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(place.priceText)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.price)
                }

                HStack(spacing: 6) {
                    Text(place.category.title)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(categoryAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(place.distanceTextShort)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Brand.gray500)

                    Label(place.ratingText, systemImage: "star.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Brand.gray300)
        }
        .padding(12)
        .background(Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Brand.gray200, lineWidth: 1)
        )
    }

    private var categoryAccent: Color {
        switch place.category {
        case .food:
            return Brand.primary
        case .cafe:
            return Brand.purple
        case .hair:
            return Brand.price
        case .lodging:
            return Brand.amber
        }
    }
}

private struct PointTransactionsCard: View {
    let isSignedIn: Bool
    let isLoading: Bool
    let message: String?
    let transactions: [PointTransactionRow]
    let onRefresh: () -> Void

    private var recentTransactions: [PointTransactionRow] {
        Array(transactions.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("포인트 장부")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text(isSignedIn ? "적립과 사용 내역을 투명하게 확인해요" : "로그인하면 포인트 내역을 확인할 수 있어요")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                Spacer()

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(isSignedIn ? Brand.primary : Brand.gray300)
                        .frame(width: 36, height: 36)
                        .background(isSignedIn ? Brand.blue50 : Brand.gray100)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isSignedIn || isLoading)
            }

            if !isSignedIn {
                MyReportsEmptyState(
                    icon: "lock.fill",
                    title: "로그인이 필요해요",
                    subtitle: "포인트는 사용자 계정과 연결되므로 로그인 후 확인할 수 있습니다."
                )
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Brand.primary)
                    Text("포인트 내역을 불러오는 중")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Brand.gray50)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if transactions.isEmpty {
                MyReportsEmptyState(
                    icon: "gift.fill",
                    title: "아직 포인트 내역이 없어요",
                    subtitle: message ?? "가격 제보가 승인되면 이곳에 적립 기록이 남습니다."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(recentTransactions) { transaction in
                        PointTransactionRowView(transaction: transaction)
                    }
                }

                if transactions.count > recentTransactions.count {
                    Text("최근 5건만 표시 중 · 전체 장부 화면은 다음 단계에서 확장")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.gray500)
                        .frame(maxWidth: .infinity, alignment: .leading)
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

private struct PointTransactionRowView: View {
    let transaction: PointTransactionRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(transaction.amountColor)
                .frame(width: 34, height: 34)
                .background(transaction.amountColor.opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(transaction.title)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    Text(transaction.amountLabel)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(transaction.amountColor)
                        .lineLimit(1)
                }

                HStack(spacing: 6) {
                    Text(transaction.typeLabel)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(transaction.amountColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(transaction.createdDateLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                }

                if let description = transaction.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                        .lineLimit(2)
                }
            }
        }
        .padding(12)
        .background(Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Brand.gray200, lineWidth: 1)
        )
    }

    private var iconName: String {
        switch transaction.transactionType {
        case "report_reward":
            return "checkmark.seal.fill"
        case "spend":
            return "cart.fill"
        default:
            return "gift.fill"
        }
    }
}

private struct MyReportsCard: View {
    let isSignedIn: Bool
    let isLoading: Bool
    let message: String?
    let reports: [MyPriceReportRow]
    let onRefresh: () -> Void

    @State private var selectedReport: MyPriceReportRow?

    private var recentReports: [MyPriceReportRow] {
        Array(reports.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("내 가격 제보")
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text(isSignedIn ? "검수 상태와 적립 예정 포인트를 확인해요" : "로그인하면 내 제보가 여기에 쌓여요")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                Spacer()

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(isSignedIn ? Brand.primary : Brand.gray300)
                        .frame(width: 36, height: 36)
                        .background(isSignedIn ? Brand.blue50 : Brand.gray100)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .disabled(!isSignedIn || isLoading)
            }

            if !isSignedIn {
                MyReportsEmptyState(
                    icon: "lock.fill",
                    title: "로그인이 필요해요",
                    subtitle: "제보 내역은 개인정보와 연결되므로 로그인한 사용자에게만 보여줍니다."
                )
            } else if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .tint(Brand.primary)
                    Text("내 제보를 불러오는 중")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Brand.gray50)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if reports.isEmpty {
                MyReportsEmptyState(
                    icon: "camera.metering.center.weighted",
                    title: "아직 제보가 없어요",
                    subtitle: message ?? "지도에서 가게를 선택하고 영수증 사진과 함께 첫 제보를 남겨보세요."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(recentReports) { report in
                        Button {
                            selectedReport = report
                        } label: {
                            MyReportRow(report: report)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if reports.count > recentReports.count {
                    Text("최근 5건만 표시 중 · 전체 내역 화면은 다음 단계에서 확장")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Brand.gray500)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        .sheet(item: $selectedReport) { report in
            MyReportDetailView(report: report)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct MyReportRow: View {
    let report: MyPriceReportRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: report.photoCount > 0 ? "photo.fill" : "doc.text.fill")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(report.photoCount > 0 ? Brand.primary : Brand.gray500)
                .frame(width: 34, height: 34)
                .background(report.photoCount > 0 ? Brand.blue50 : Brand.gray100)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(report.menuName)
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(report.reportedPrice.formatted())원")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.price)
                }

                HStack(spacing: 6) {
                    Text(report.statusLabel)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(report.statusColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(report.photoLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Brand.gray500)

                    Text("+\(report.rewardPoints)P 예정")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Brand.primary)
                }

                if let memo = report.memo, !memo.isEmpty {
                    Text(memo)
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                        .lineLimit(2)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.heavy))
                .foregroundStyle(Brand.gray300)
                .padding(.top, 4)
        }
        .padding(12)
        .background(Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Brand.gray200, lineWidth: 1)
        )
    }
}

private struct MyReportDetailView: View {
    let report: MyPriceReportRow

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(report.menuName)
                                    .font(.title3.weight(.heavy))
                                    .foregroundStyle(Brand.gray900)
                                Text("\(report.reportedPrice.formatted())원")
                                    .font(.title2.weight(.heavy))
                                    .foregroundStyle(Brand.price)
                            }

                            Spacer()

                            Text(report.statusLabel)
                                .font(.caption.weight(.heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(report.statusColor)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        }

                        Text(statusDescription)
                            .font(.caption)
                            .foregroundStyle(Brand.gray500)
                            .lineSpacing(2)
                    }
                    .padding(16)
                    .background(Brand.blue50)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.blue100, lineWidth: 1)
                    )

                    VStack(spacing: 10) {
                        ReportDetailInfoRow(icon: "calendar", title: "방문일", value: report.visitDateLabel)
                        ReportDetailInfoRow(icon: "tray.and.arrow.up.fill", title: "제보 등록일", value: report.createdDateLabel)
                        ReportDetailInfoRow(icon: "checkmark.seal.fill", title: "검수일", value: report.reviewedDateLabel)
                        ReportDetailInfoRow(icon: "photo.on.rectangle.angled", title: "인증 사진", value: report.uploadStatusLabel)
                        ReportDetailInfoRow(icon: "gift.fill", title: "적립 예정", value: "+\(report.rewardPoints)P")
                        ReportDetailInfoRow(icon: "creditcard.fill", title: "포인트 지급", value: report.pointGrantedDateLabel)
                    }
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.gray200, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.reportStatus == "rejected" ? "반려 사유" : "운영자 메모")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)

                        Text(report.reviewMessage)
                            .font(.subheadline)
                            .foregroundStyle(report.reportStatus == "rejected" ? Brand.red : Brand.gray700)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(report.reportStatus == "rejected" ? Color(hex: "#FEF2F2") : Brand.gray50)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.gray200, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("제보 메모")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)

                        Text((report.memo?.isEmpty == false ? report.memo : "남긴 메모가 없어요.") ?? "남긴 메모가 없어요.")
                            .font(.subheadline)
                            .foregroundStyle(Brand.gray700)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(Brand.gray50)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.gray200, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("운영 안내")
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.gray900)
                        Text("가격 제보는 운영자가 영수증과 인증 사진을 확인한 뒤 승인됩니다. 승인되면 예정 포인트가 실제 포인트로 전환되는 구조로 확장할 예정입니다.")
                            .font(.caption)
                            .foregroundStyle(Brand.gray500)
                            .lineSpacing(3)
                    }
                    .padding(14)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Brand.gray200, lineWidth: 1)
                    )
                }
                .padding(14)
            }
            .background(Brand.gray50)
            .navigationTitle("제보 상세")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var statusDescription: String {
        switch report.reportStatus {
        case "approved":
            return "운영자 검수가 완료된 제보예요. 로그인 제보라면 포인트 장부에 함께 반영됩니다."
        case "rejected":
            return "검수 기준에 맞지 않아 반려된 제보예요. 추후 반려 사유 표시 기능을 연결할 예정입니다."
        default:
            return "현재 운영자 검수 대기 중이에요. 영수증과 인증 사진이 선명할수록 승인 가능성이 높아집니다."
        }
    }
}

private struct ReportDetailInfoRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.caption.weight(.heavy))
                .foregroundStyle(Brand.primary)
                .frame(width: 30, height: 30)
                .background(Brand.blue50)
                .clipShape(RoundedRectangle(cornerRadius: 9))

            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Brand.gray700)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Brand.gray900)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct MyReportsEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Brand.primary)
                .frame(width: 38, height: 38)
                .background(Brand.blue50)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Brand.gray900)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Brand.gray500)
                    .lineSpacing(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct PasswordResetSheet: View {
    let recoverySession: PasswordResetSession
    let isLoading: Bool
    let message: String?
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var localMessage: String?

    private var canSubmit: Bool {
        newPassword.count >= 6 && newPassword == confirmPassword
    }

    private var expiryText: String {
        guard let expiresAt = recoverySession.expiresAt else {
            return "링크 만료 시간 확인 중"
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M월 d일 HH:mm"
        return "\(formatter.string(from: expiresAt))까지 유효"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("새 비밀번호 설정")
                        .font(.title3.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Text("메일에서 열린 재설정 링크를 확인했어요.")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                VStack(alignment: .leading, spacing: 10) {
                    SecureField("새 비밀번호 6자 이상", text: $newPassword)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(Brand.gray50)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Brand.gray200, lineWidth: 1)
                        )

                    SecureField("새 비밀번호 확인", text: $confirmPassword)
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .frame(height: 46)
                        .background(Brand.gray50)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Brand.gray200, lineWidth: 1)
                        )

                    if !confirmPassword.isEmpty && newPassword != confirmPassword {
                        Text("비밀번호가 서로 달라요.")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Brand.red)
                    }
                }

                HStack(spacing: 8) {
                    Image(systemName: "clock.fill")
                        .foregroundStyle(Brand.primary)
                    Text(expiryText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.gray700)
                }
                .padding(12)
                .background(Brand.blue50)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                if let message = localMessage ?? message {
                    Text(message)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(message.contains("변경") ? Brand.price : Brand.red)
                }

                Spacer()

                Button {
                    guard canSubmit else {
                        localMessage = newPassword.count < 6 ? "새 비밀번호는 6자 이상이어야 해요." : "비밀번호 확인이 일치하지 않아요."
                        return
                    }
                    localMessage = nil
                    onSubmit(newPassword)
                } label: {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(isLoading ? "변경 중" : "비밀번호 변경")
                    }
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(canSubmit && !isLoading ? Brand.primary : Brand.gray300)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }
            .padding(18)
            .background(Brand.gray50)
            .navigationTitle("비밀번호 재설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("닫기", action: onCancel)
                        .font(.subheadline.weight(.bold))
                }
            }
        }
    }
}

private struct AuthFormCard: View {
    @Binding var email: String
    @Binding var password: String
    @Binding var displayName: String
    @Binding var isSignUpMode: Bool
    let isLoading: Bool
    let message: String?
    let onSubmit: () -> Void
    let onPasswordReset: () -> Void
    let onDiagnose: () -> Void

    private var canSubmit: Bool {
        email.contains("@") && password.count >= 6 && (!isSignUpMode || !displayName.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(isSignUpMode ? "회원가입" : "로그인")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Brand.gray900)
                Spacer()
                Button {
                    isSignUpMode.toggle()
                } label: {
                    Text(isSignUpMode ? "로그인으로" : "가입하기")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
            }

            if AppEnvironment.showsInternalTools {
                Button {
                    isSignUpMode = true
                    displayName = "짠테크 QA"
                    email = "jjantechmap.qa@gmail.com"
                    password = ""
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "wand.and.stars")
                        Text("QA 샘플값 채우기")
                        Spacer()
                        Text("테스트용")
                    }
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Brand.primary)
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Brand.blue50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }

            if AppEnvironment.showsInternalTools {
                AuthQAGuideBox()
            }

            if isSignUpMode {
                StyledTextField(title: "닉네임", text: $displayName)
            }

            StyledTextField(title: "이메일", text: $email)
                .textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()

            SecureField("비밀번호 6자 이상", text: $password)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(Brand.gray50)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Brand.gray200, lineWidth: 1)
                )

            if !isSignUpMode {
                Button(action: onPasswordReset) {
                    HStack(spacing: 6) {
                        Image(systemName: "questionmark.circle.fill")
                        Text("비밀번호를 잊으셨나요?")
                    }
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
            }

            if let message {
                Text(message)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(message.contains("완료") || message.contains("정상") ? Brand.price : Brand.red)
                    .lineSpacing(2)
            }

            Button(action: onSubmit) {
                HStack(spacing: 8) {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(isLoading ? "처리 중" : (isSignUpMode ? "회원가입하고 시작" : "로그인"))
                }
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(canSubmit && !isLoading ? Brand.primary : Brand.gray300)
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit || isLoading)

            if !isSignUpMode && AppEnvironment.showsInternalTools {
                Button(action: onDiagnose) {
                    HStack(spacing: 8) {
                        Image(systemName: "stethoscope")
                        Text(isLoading ? "점검 중" : "계정 상태 점검")
                    }
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(canSubmit && !isLoading ? Brand.primary : Brand.gray500)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(canSubmit && !isLoading ? Brand.blue50 : Brand.gray50)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(canSubmit && !isLoading ? Brand.blue100 : Brand.gray200, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit || isLoading)
            }

            Text(isSignUpMode ? "가입 후 이메일 확인이 필요한 경우 메일함에서 인증을 완료해주세요." : "가입한 이메일로 비밀번호 재설정 메일을 받을 수 있어요.")
                .font(.caption2)
                .foregroundStyle(Brand.gray500)
                .lineSpacing(2)
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

private struct AuthQAGuideBox: View {
    @State private var copiedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield.fill")
                Text("QA 계정이 없으면 로그인되지 않아요")
            }
            .font(.caption.weight(.heavy))
            .foregroundStyle(Brand.gray900)

            Text("Supabase > Authentication > Users에서 `jjantechmap.qa@gmail.com` 유저를 직접 만들고 Confirm 처리한 뒤 로그인해주세요.")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Brand.gray500)
                .lineSpacing(2)

            VStack(alignment: .leading, spacing: 5) {
                AuthDiagnosisLine(
                    icon: "xmark.octagon.fill",
                    title: "현재 진단",
                    text: "로그인 API가 `invalid_credentials`를 반환 중이에요.",
                    color: Brand.red
                )
                AuthDiagnosisLine(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "가장 흔한 원인",
                    text: "Supabase Auth에 해당 이메일 유저가 없거나 비밀번호가 달라요.",
                    color: Brand.amber
                )
                AuthDiagnosisLine(
                    icon: "checkmark.seal.fill",
                    title: "해결 기준",
                    text: "Users 목록에 유저가 있고 Confirmed 상태면 앱 로그인이 됩니다.",
                    color: Brand.price
                )
            }
            .padding(9)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(Brand.gray200, lineWidth: 1)
            )

            HStack(spacing: 8) {
                AuthCopyButton(title: "이메일 복사", value: "jjantechmap.qa@gmail.com") {
                    copiedMessage = "이메일을 복사했어요."
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                AuthChecklistLine(number: "1", text: "Authentication > Users > Add user")
                AuthChecklistLine(number: "2", text: "복사한 이메일과 별도 보관한 QA 비밀번호 입력")
                AuthChecklistLine(number: "3", text: "Auto Confirm User 또는 Confirm 켜기")
                AuthChecklistLine(number: "4", text: "앱에서 이메일 입력 후 로그인")
            }
            .padding(.top, 2)

            if let copiedMessage {
                Text(copiedMessage)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Brand.price)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
                            if self.copiedMessage == copiedMessage {
                                self.copiedMessage = nil
                            }
                        }
                    }
            }
        }
        .padding(10)
        .background(Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Brand.gray200, lineWidth: 1)
        )
    }
}

private struct AuthDiagnosisLine: View {
    let icon: String
    let title: String
    let text: String
    let color: Color

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .font(.caption.weight(.heavy))
                .foregroundStyle(color)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Brand.gray900)
                Text(text)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Brand.gray500)
                    .lineSpacing(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AuthChecklistLine: View {
    let number: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(number)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Brand.primary)
                .clipShape(Circle())

            Text(text)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Brand.gray700)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AuthCopyButton: View {
    let title: String
    let value: String
    let onCopy: () -> Void

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onCopy()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc.fill")
                Text(title)
            }
            .font(.caption2.weight(.heavy))
            .foregroundStyle(Brand.primary)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Brand.blue100, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct ExploreHeader: View {
    @Binding var selectedCategory: PlaceCategory
    let locationStatus: CLAuthorizationStatus
    let hasLiveLocation: Bool
    let onRequestLocation: () -> Void

    private var locationLabel: String {
        switch locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return hasLiveLocation ? "실시간 위치 확인 중" : "위치 수신 중…"
        case .denied, .restricted:
            return "위치 권한이 꺼져있어요"
        default:
            return "위치 권한을 허용해주세요"
        }
    }

    private var indicatorColor: Color {
        switch locationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return hasLiveLocation ? Color(hex: "#34D399") : Color(hex: "#FCD34D")
        default:
            return Color(hex: "#F87171")
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HeaderTop()

            Button(action: onRequestLocation) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(indicatorColor)
                        .frame(width: 8, height: 8)
                    Text(locationLabel)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Image(systemName: hasLiveLocation ? "location.fill" : "location")
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.white.opacity(0.18))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .foregroundStyle(.white)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .background(.white.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            CategoryPills(selectedCategory: $selectedCategory, lightStyle: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Brand.primary.ignoresSafeArea(edges: .top))
    }
}

private struct MapHeader: View {
    @Binding var selectedCategory: PlaceCategory
    let isListMode: Bool
    let onMapTap: () -> Void
    let onListTap: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                LogoText()
                Spacer()
                HStack(spacing: 6) {
                    Button(action: onMapTap) {
                        Text("지도")
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(isListMode ? .white : Brand.primary)
                            .background(isListMode ? .white.opacity(0.14) : .white)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button(action: onListTap) {
                        Text("리스트")
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .foregroundStyle(isListMode ? Brand.primary : .white)
                            .background(isListMode ? .white : .white.opacity(0.14))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            CategoryPills(selectedCategory: $selectedCategory, lightStyle: true)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .background(Brand.primary.ignoresSafeArea(edges: .top))
    }
}

private struct HeaderTop: View {
    var body: some View {
        HStack {
            LogoText()
            Spacer()
            HStack(spacing: 8) {
                HeaderIcon(systemImage: "bell.fill")
                HeaderIcon(systemImage: "gearshape.fill")
            }
        }
    }
}

private struct LogoText: View {
    var body: some View {
        HStack(spacing: 0) {
            Text("짠테크")
                .font(.headline.weight(.heavy))
                .foregroundStyle(.white)
            Text("맵")
                .font(.headline.weight(.heavy))
                .foregroundStyle(Color(hex: "#7DD3FC"))
        }
    }
}

private struct HeaderIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(.white.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CategoryPills: View {
    @Binding var selectedCategory: PlaceCategory
    let lightStyle: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(PlaceCategory.allCases) { category in
                    Button {
                        selectedCategory = category
                    } label: {
                        HStack(spacing: 5) {
                            Text(category.icon)
                            Text(category.title)
                        }
                        .font(.caption.weight(.heavy))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .foregroundStyle(selectedCategory == category ? Brand.primary600 : .white.opacity(0.88))
                        .background(selectedCategory == category ? .white : .white.opacity(0.13))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct PlaceCard: View {
    let place: Place

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(place.icon)
                .font(.system(size: 24))
                .frame(width: 56, height: 56)
                .background(place.category.softColor)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    Text(place.name)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                    Spacer()
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(Brand.amber)
                        Text(place.ratingText)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Brand.gray500)
                    }
                }

                HStack(spacing: 7) {
                    Text(place.kind)
                        .font(.caption2.weight(.heavy))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(Brand.primary700)
                        .background(Brand.blue50)
                        .clipShape(RoundedRectangle(cornerRadius: 7))

                    Text(place.distanceText)
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }

                HStack(alignment: .bottom) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("부터")
                            .font(.caption2)
                            .foregroundStyle(Brand.gray500)
                        Text(place.priceText)
                            .font(.headline.weight(.heavy))
                            .foregroundStyle(Brand.price)
                    }

                    Spacer()

                    VerifyBadge(isVerified: place.isVerified, text: place.verifyText)
                }
            }
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(place.isFeatured ? Brand.blue100 : Brand.gray200, lineWidth: place.isFeatured ? 1.5 : 1)
        )
    }
}

private struct VerifyBadge: View {
    let isVerified: Bool
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isVerified ? Brand.price : Brand.amber)
                .frame(width: 6, height: 6)
            Text(text)
                .lineLimit(1)
        }
        .font(.caption2.weight(.heavy))
        .foregroundStyle(isVerified ? Color(hex: "#065F46") : Color(hex: "#92400E"))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isVerified ? Color(hex: "#ECFDF5") : Color(hex: "#FFFBEB"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct PriceMarker: View {
    let price: Int
    let tint: Color
    let isSelected: Bool

    var body: some View {
        VStack(spacing: -2) {
            Text("\(price.formatted())원")
                .font(.caption.weight(.heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(tint)
                .clipShape(Capsule())
                .scaleEffect(isSelected ? 1.1 : 1)
                .shadow(color: tint.opacity(0.35), radius: 8, y: 3)

            Image(systemName: "triangle.fill")
                .font(.caption2)
                .rotationEffect(.degrees(180))
                .foregroundStyle(tint)
        }
    }
}

private struct MapLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LegendRow(color: .red, text: "식당")
            LegendRow(color: Brand.purple, text: "카페")
            LegendRow(color: Brand.price, text: "미용실")
            LegendRow(color: Brand.primary, text: "숙박")
        }
        .padding(10)
        .background(.white.opacity(0.94))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.black.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct LegendRow: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 11, height: 11)
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Brand.gray700)
        }
    }
}

private struct MapFilterPanel: View {
    let options: [String]
    @Binding var draftFilters: Set<String>
    let defaultFilters: Set<String>
    let onApply: () -> Void
    let onReset: () -> Void
    let onCancel: () -> Void

    private var isDirty: Bool { draftFilters != defaultFilters }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("빠른 필터", systemImage: "slider.horizontal.3")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Brand.gray900)
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Brand.gray500)
                        .frame(width: 22, height: 22)
                        .background(Brand.gray100)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            ForEach(options, id: \.self) { option in
                Button {
                    if draftFilters.contains(option) {
                        draftFilters.remove(option)
                    } else {
                        draftFilters.insert(option)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: draftFilters.contains(option) ? "checkmark.circle.fill" : "circle")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(draftFilters.contains(option) ? Brand.primary : Brand.gray300)
                        Text(option)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Brand.gray700)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(draftFilters.contains(option) ? Brand.blue50 : Brand.gray50)
                    .clipShape(RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Button(action: onReset) {
                    Text("초기화")
                        .font(.caption.weight(.heavy))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .foregroundStyle(isDirty ? Brand.gray700 : Brand.gray300)
                        .background(Brand.gray50)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Brand.gray200, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!isDirty)

                Button(action: onApply) {
                    Text("적용")
                        .font(.caption.weight(.heavy))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .foregroundStyle(.white)
                        .background(Brand.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 4)
        }
        .padding(12)
        .frame(width: 188)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 17))
        .overlay(
            RoundedRectangle(cornerRadius: 17)
                .stroke(Brand.gray200, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.13), radius: 14, y: 6)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct MiniPlaceCard: View {
    let place: Place
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(place.name)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Brand.gray900)
                .lineLimit(1)
            Text("\(place.priceText)~")
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(Brand.price)
            Text("\(place.distanceTextShort) · ★ \(place.ratingText)")
                .font(.caption)
                .foregroundStyle(Brand.gray500)
        }
        .frame(width: 140, alignment: .leading)
        .padding(12)
        .background(isSelected ? Brand.blue50 : Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isSelected ? Brand.primary.opacity(0.65) : Brand.gray200, lineWidth: isSelected ? 2 : 1)
        )
    }
}

private struct MapBottomSheet: View {
    let places: [Place]
    let selectedCategory: PlaceCategory
    @Binding var selectedPlaceID: UUID?
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    isExpanded.toggle()
                }
            } label: {
                Capsule()
                    .fill(Brand.gray300)
                    .frame(width: 48, height: 5)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            HStack {
                Text("주변 \(places.count)곳 발견 · \(selectedCategory.title) 최저가")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Brand.gray700)
                Spacer()
                Text("1km")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Brand.primary)
            }

            if places.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Brand.gray300)
                    Text("조건에 맞는 장소가 없어요")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(Brand.gray700)
                    Text("필터를 초기화하거나 카테고리를 바꿔보세요.")
                        .font(.caption)
                        .foregroundStyle(Brand.gray500)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else if isExpanded {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(places) { place in
                            NavigationLink {
                                PlaceDetailView(place: place)
                            } label: {
                                ExpandedMapPlaceRow(place: place, isSelected: selectedPlaceID == place.id)
                            }
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    selectedPlaceID = place.id
                                }
                            )
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(places) { place in
                            NavigationLink {
                                PlaceDetailView(place: place)
                            } label: {
                                MiniPlaceCard(place: place, isSelected: selectedPlaceID == place.id)
                            }
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    selectedPlaceID = place.id
                                }
                            )
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 4)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24)
                .fill(.white)
                .shadow(color: .black.opacity(0.12), radius: 16, y: -4)
        )
        .gesture(
            DragGesture(minimumDistance: 16)
                .onEnded { value in
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        if value.translation.height < -45 {
                            isExpanded = true
                        } else if value.translation.height > 45 {
                            isExpanded = false
                        }
                    }
                }
        )
    }
}

private struct ExpandedMapPlaceRow: View {
    let place: Place
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(place.icon)
                .font(.title2)
                .frame(width: 52, height: 52)
                .background(place.category.softColor)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(place.name)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(Brand.gray900)
                        .lineLimit(1)
                    if place.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption)
                            .foregroundStyle(Brand.price)
                    }
                }

                Text("\(place.kind) · \(place.distanceTextShort) · ★ \(place.ratingText)")
                    .font(.caption)
                    .foregroundStyle(Brand.gray500)

                Text(place.tip)
                    .font(.caption)
                    .foregroundStyle(Brand.gray500)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(place.priceText)~")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(Brand.price)
                Text(place.statusText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Brand.primary)
            }
        }
        .padding(12)
        .background(isSelected ? Brand.blue50 : Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? Brand.primary.opacity(0.65) : Brand.gray200, lineWidth: isSelected ? 2 : 1)
        )
    }
}

private struct DetailSection<Content: View>: View {
    private let title: String?
    private let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Brand.gray500)
                    .tracking(0.8)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Brand.gray200, lineWidth: 1)
        )
    }
}

private struct DetailMetric: View {
    let value: String
    let label: String
    var valueColor: Color = Brand.primary

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.headline.weight(.heavy))
                .foregroundStyle(valueColor)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Brand.gray500)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(Brand.blue50)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct MenuPriceRow: View {
    let menu: MenuItem

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(menu.name)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Brand.gray900)
                Text(menu.description)
                    .font(.caption)
                    .foregroundStyle(Brand.gray500)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                Text("\(menu.price.formatted())원")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Brand.price)
                Text(menu.verified ? "인증됨" : "확인권장")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(menu.verified ? Brand.price : Brand.amber)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Brand.gray100)
                .frame(height: 1)
        }
    }
}

private struct CircleIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

private struct FormCard<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Brand.gray500)
                .tracking(0.7)
            content
        }
        .padding(14)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 15))
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Brand.gray200, lineWidth: 1)
        )
    }
}

private struct StyledTextField: View {
    let title: String
    @Binding var text: String
    var suffix: String? = nil

    var body: some View {
        HStack {
            TextField(title, text: $text)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.gray900)
            if let suffix {
                Text(suffix)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(Brand.primary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Brand.gray50)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(Brand.gray200, lineWidth: 1)
        )
    }
}

private struct PhotoThumb: View {
    var systemImage: String? = nil
    var image: UIImage? = nil
    var isDashed = false
    var onRemove: (() -> Void)? = nil

    init(systemImage: String, isDashed: Bool = false) {
        self.systemImage = systemImage
        self.image = nil
        self.isDashed = isDashed
        self.onRemove = nil
    }

    init(image: UIImage, onRemove: @escaping () -> Void) {
        self.systemImage = nil
        self.image = image
        self.isDashed = false
        self.onRemove = onRemove
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                } else if let systemImage {
                    Image(systemName: systemImage)
                        .font(.headline)
                        .foregroundStyle(Brand.primary)
                        .frame(width: 56, height: 56)
                        .background(isDashed ? Brand.blue50 : Brand.blue100.opacity(0.55))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Brand.blue100, style: StrokeStyle(lineWidth: isDashed ? 2 : 1, dash: isDashed ? [5] : []))
            )

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 18, height: 18)
                        .background(Brand.gray900.opacity(0.86))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 5, y: -5)
            }
        }
    }
}

private struct StatBox: View {
    let number: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Text(number)
                .font(.headline.weight(.heavy))
                .foregroundStyle(Brand.primary)
                .minimumScaleFactor(0.75)
                .lineLimit(1)
            Text(label)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(Brand.gray500)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 13)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(Brand.gray200, lineWidth: 1)
        )
    }
}

private struct SavingBox: View {
    let title: String
    let amount: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.heavy))
                .foregroundStyle(color)
            Text(amount)
                .font(.caption)
                .foregroundStyle(Brand.gray500)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Brand.blue100, lineWidth: 1)
        )
    }
}

private struct MyMenuRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var badge: String? = nil
    let iconColor: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(iconColor)
                .frame(width: 34, height: 34)
                .background(iconColor.opacity(0.11))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(Brand.gray900)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Brand.gray500)
            }

            Spacer()

            if let badge {
                Text(badge)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Brand.red)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(Brand.gray300)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Brand.gray100)
                .frame(height: 1)
                .padding(.leading, 60)
        }
    }
}

// MARK: - Models

private enum MainTab: Hashable {
    case explore
    case map
    case youth
    case flea
    case my
}

enum PlaceCategory: CaseIterable, Identifiable {
    case food
    case cafe
    case hair
    case lodging

    var id: Self { self }

    init?(databaseValue: String) {
        switch databaseValue {
        case "food":
            self = .food
        case "cafe":
            self = .cafe
        case "hair":
            self = .hair
        case "lodging":
            self = .lodging
        default:
            return nil
        }
    }

    var databaseValue: String {
        switch self {
        case .food:
            return "food"
        case .cafe:
            return "cafe"
        case .hair:
            return "hair"
        case .lodging:
            return "lodging"
        }
    }

    var title: String {
        switch self {
        case .food:
            return "식당"
        case .cafe:
            return "카페"
        case .hair:
            return "미용실"
        case .lodging:
            return "숙박"
        }
    }

    var icon: String {
        switch self {
        case .food:
            return "🍽"
        case .cafe:
            return "☕"
        case .hair:
            return "✂️"
        case .lodging:
            return "🏨"
        }
    }

    var softColor: Color {
        switch self {
        case .food:
            return Brand.blue50
        case .cafe:
            return Brand.purple.opacity(0.12)
        case .hair:
            return Brand.green50
        case .lodging:
            return Brand.amber.opacity(0.12)
        }
    }
}

struct Place: Identifiable {
    let id: UUID
    let name: String
    let category: PlaceCategory
    let kind: String
    let icon: String
    let distanceText: String
    let distanceTextShort: String
    let basePrice: Int
    let rating: Double
    let reviewCount: Int
    let isVerified: Bool
    let verifyText: String
    let isFeatured: Bool
    let trustScore: Int
    let receiptCount: Int
    let updatedText: String
    let openTime: String
    let statusText: String
    let address: String
    let stationNote: String
    let coordinate: CLLocationCoordinate2D
    let menus: [MenuItem]
    let tip: String

    init(
        id: UUID = UUID(),
        name: String,
        category: PlaceCategory,
        kind: String,
        icon: String,
        distanceText: String,
        distanceTextShort: String,
        basePrice: Int,
        rating: Double,
        reviewCount: Int,
        isVerified: Bool,
        verifyText: String,
        isFeatured: Bool,
        trustScore: Int,
        receiptCount: Int,
        updatedText: String,
        openTime: String,
        statusText: String,
        address: String,
        stationNote: String,
        coordinate: CLLocationCoordinate2D,
        menus: [MenuItem],
        tip: String
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.kind = kind
        self.icon = icon
        self.distanceText = distanceText
        self.distanceTextShort = distanceTextShort
        self.basePrice = basePrice
        self.rating = rating
        self.reviewCount = reviewCount
        self.isVerified = isVerified
        self.verifyText = verifyText
        self.isFeatured = isFeatured
        self.trustScore = trustScore
        self.receiptCount = receiptCount
        self.updatedText = updatedText
        self.openTime = openTime
        self.statusText = statusText
        self.address = address
        self.stationNote = stationNote
        self.coordinate = coordinate
        self.menus = menus
        self.tip = tip
    }

    var priceText: String {
        "\(basePrice.formatted())원"
    }

    var ratingText: String {
        String(format: "%.1f", rating)
    }

    var distanceMeters: Int {
        let digits = distanceTextShort.filter(\.isNumber)
        return Int(digits) ?? Int.max
    }

    func matchesSearch(_ query: String) -> Bool {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty == false else { return true }

        let searchableTexts = [
            name,
            category.title,
            kind,
            address,
            stationNote,
            tip
        ] + menus.flatMap { [$0.name, $0.description] }

        return searchableTexts.contains {
            $0.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    static let mock: [Place] = [
        Place(
            name: "합정 칼국수",
            category: .food,
            kind: "한식",
            icon: "🍜",
            distanceText: "도보 3분 · 230m",
            distanceTextShort: "230m",
            basePrice: 6000,
            rating: 4.6,
            reviewCount: 84,
            isVerified: true,
            verifyText: "인증됨 · 2일전",
            isFeatured: false,
            trustScore: 82,
            receiptCount: 2,
            updatedText: "2일 전 확인",
            openTime: "10:30",
            statusText: "영업중",
            address: "서울 마포구 독막로 18길 7",
            stationNote: "합정역 7번 출구 도보 3분",
            coordinate: CLLocationCoordinate2D(latitude: 37.5492, longitude: 126.9140),
            menus: [
                MenuItem(name: "손칼국수", description: "멸치 육수 · 김치 제공", price: 6000, verified: true),
                MenuItem(name: "왕만두", description: "직접 빚은 만두 6개", price: 5000, verified: true),
                MenuItem(name: "칼만두국", description: "칼국수와 만두 한 그릇", price: 7500, verified: false)
            ],
            tip: "혼밥 좌석이 많고 점심 회전이 빨라요. 현금 결제 시 곱빼기 추가가 무료인 날이 있어요."
        ),
        Place(
            name: "동네 백반집",
            category: .food,
            kind: "백반",
            icon: "🍱",
            distanceText: "도보 5분 · 380m",
            distanceTextShort: "380m",
            basePrice: 7000,
            rating: 4.8,
            reviewCount: 127,
            isVerified: true,
            verifyText: "인증됨 · 오늘",
            isFeatured: true,
            trustScore: 87,
            receiptCount: 3,
            updatedText: "오늘 확인",
            openTime: "11:00",
            statusText: "영업중",
            address: "서울 마포구 합정동 123-4",
            stationNote: "합정역 2번 출구 도보 5분",
            coordinate: CLLocationCoordinate2D(latitude: 37.5511, longitude: 126.9133),
            menus: [
                MenuItem(name: "백반 (4찬)", description: "매일 바뀌는 반찬 · 밥 무한리필", price: 7000, verified: true),
                MenuItem(name: "된장찌개 정식", description: "국내산 된장 · 공기밥 포함", price: 8000, verified: true),
                MenuItem(name: "제육볶음 정식", description: "매콤한 제육 · 공기밥 포함", price: 9000, verified: false)
            ],
            tip: "11시 30분 전에 가면 대기 없이 앉기 좋아요. 오늘 반찬은 계란말이, 오이무침, 어묵볶음, 김치예요."
        ),
        Place(
            name: "샐러드공장",
            category: .food,
            kind: "샐러드",
            icon: "🥗",
            distanceText: "도보 7분 · 520m",
            distanceTextShort: "520m",
            basePrice: 8500,
            rating: 4.3,
            reviewCount: 51,
            isVerified: false,
            verifyText: "확인권장",
            isFeatured: false,
            trustScore: 69,
            receiptCount: 1,
            updatedText: "9일 전 확인",
            openTime: "09:30",
            statusText: "영업중",
            address: "서울 마포구 양화로 45",
            stationNote: "상수역 1번 출구 도보 7분",
            coordinate: CLLocationCoordinate2D(latitude: 37.5481, longitude: 126.9172),
            menus: [
                MenuItem(name: "닭가슴살 샐러드", description: "현미 토핑 포함", price: 8500, verified: false),
                MenuItem(name: "두부 샐러드", description: "오리엔탈 드레싱", price: 7900, verified: true),
                MenuItem(name: "아메리카노 세트", description: "샐러드 주문 시 할인", price: 10500, verified: false)
            ],
            tip: "앱 포장 주문을 쓰면 점심 피크에도 10분 안에 받을 수 있어요."
        ),
        Place(
            name: "마포 순대국",
            category: .food,
            kind: "국밥",
            icon: "🍲",
            distanceText: "도보 9분 · 680m",
            distanceTextShort: "680m",
            basePrice: 9000,
            rating: 4.5,
            reviewCount: 96,
            isVerified: true,
            verifyText: "인증됨 · 5일전",
            isFeatured: false,
            trustScore: 78,
            receiptCount: 2,
            updatedText: "5일 전 확인",
            openTime: "08:00",
            statusText: "영업중",
            address: "서울 마포구 월드컵로 12",
            stationNote: "망원역 1번 출구 도보 9분",
            coordinate: CLLocationCoordinate2D(latitude: 37.5552, longitude: 126.9108),
            menus: [
                MenuItem(name: "순대국", description: "공기밥 포함", price: 9000, verified: true),
                MenuItem(name: "머리고기 소", description: "2인 추천", price: 12000, verified: true),
                MenuItem(name: "얼큰 순대국", description: "청양고추 추가", price: 9500, verified: false)
            ],
            tip: "아침 식사가 가능하고 포장 시 국물을 넉넉하게 줘요."
        ),
        Place(
            name: "망원 동네카페",
            category: .cafe,
            kind: "커피",
            icon: "☕",
            distanceText: "도보 4분 · 300m",
            distanceTextShort: "300m",
            basePrice: 2500,
            rating: 4.7,
            reviewCount: 73,
            isVerified: true,
            verifyText: "인증됨 · 오늘",
            isFeatured: false,
            trustScore: 91,
            receiptCount: 5,
            updatedText: "오늘 확인",
            openTime: "08:30",
            statusText: "영업중",
            address: "서울 마포구 포은로 31",
            stationNote: "망원역 2번 출구 도보 4분",
            coordinate: CLLocationCoordinate2D(latitude: 37.5539, longitude: 126.9165),
            menus: [
                MenuItem(name: "아메리카노", description: "테이크아웃 동일 가격", price: 2500, verified: true),
                MenuItem(name: "카페라떼", description: "우유 변경 가능", price: 3500, verified: true),
                MenuItem(name: "오늘의 쿠키", description: "수량 한정", price: 2800, verified: true)
            ],
            tip: "오전 11시 전 방문하면 아메리카노 리필 1회가 가능해요."
        ),
        Place(
            name: "홍대 컷트샵",
            category: .hair,
            kind: "미용실",
            icon: "✂️",
            distanceText: "도보 8분 · 620m",
            distanceTextShort: "620m",
            basePrice: 8000,
            rating: 4.2,
            reviewCount: 44,
            isVerified: true,
            verifyText: "인증됨 · 3일전",
            isFeatured: false,
            trustScore: 74,
            receiptCount: 2,
            updatedText: "3일 전 확인",
            openTime: "10:00",
            statusText: "영업중",
            address: "서울 마포구 와우산로 87",
            stationNote: "홍대입구역 8번 출구 도보 8분",
            coordinate: CLLocationCoordinate2D(latitude: 37.5504, longitude: 126.9215),
            menus: [
                MenuItem(name: "남성 컷", description: "샴푸 별도", price: 8000, verified: true),
                MenuItem(name: "앞머리 컷", description: "예약 없이 가능", price: 3000, verified: true),
                MenuItem(name: "다운펌", description: "커트 포함", price: 25000, verified: false)
            ],
            tip: "평일 오전 방문 시 대기 시간이 짧고 현장 결제만 가능해요."
        ),
        Place(
            name: "합정 게스트하우스",
            category: .lodging,
            kind: "숙박",
            icon: "🏨",
            distanceText: "도보 11분 · 820m",
            distanceTextShort: "820m",
            basePrice: 45000,
            rating: 4.4,
            reviewCount: 63,
            isVerified: true,
            verifyText: "인증됨 · 1일전",
            isFeatured: false,
            trustScore: 80,
            receiptCount: 2,
            updatedText: "1일 전 확인",
            openTime: "15:00",
            statusText: "예약가능",
            address: "서울 마포구 양화진길 22",
            stationNote: "합정역 5번 출구 도보 11분",
            coordinate: CLLocationCoordinate2D(latitude: 37.5469, longitude: 126.9106),
            menus: [
                MenuItem(name: "도미토리 1박", description: "평일 기준", price: 45000, verified: true),
                MenuItem(name: "싱글룸 1박", description: "공용 욕실", price: 69000, verified: false),
                MenuItem(name: "짐 보관", description: "투숙객 무료", price: 0, verified: true)
            ],
            tip: "평일 예약이 주말보다 2만원가량 저렴하고, 체크인 전 짐 보관이 가능해요."
        )
    ]
}

struct MenuItem: Identifiable {
    let id: UUID
    let name: String
    let description: String
    let price: Int
    let referencePrice: Int?
    let verified: Bool

    init(
        id: UUID = UUID(),
        name: String,
        description: String,
        price: Int,
        referencePrice: Int? = nil,
        verified: Bool
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.price = price
        self.referencePrice = referencePrice
        self.verified = verified
    }
}

// MARK: - Location

final class JjantechLocationManager: NSObject, ObservableObject {
    static let shared = JjantechLocationManager()

    private let manager = CLLocationManager()

    @Published var coordinate: CLLocationCoordinate2D?
    @Published var heading: CLLocationDirection = 0
    @Published var authorizationStatus: CLAuthorizationStatus
    @Published var lastError: String?
    @Published private(set) var isUpdating = false

    override init() {
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorizedWhenInUse || authorizationStatus == .authorizedAlways
    }

    func requestPermissionAndStart() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            startUpdating()
        case .denied, .restricted:
            lastError = "위치 권한이 차단되어 있어요. 설정 앱에서 허용해주세요."
        @unknown default:
            break
        }
    }

    func startUpdating() {
        guard isAuthorized else { return }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() {
            manager.startUpdatingHeading()
        }
        isUpdating = true
        lastError = nil
    }

    func stopUpdating() {
        manager.stopUpdatingLocation()
        manager.stopUpdatingHeading()
        isUpdating = false
    }
}

extension JjantechLocationManager: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if isAuthorized {
            startUpdating()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        coordinate = last.coordinate
        lastError = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        heading = newHeading.trueHeading
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let nsError = error as NSError
        guard nsError.code != CLError.locationUnknown.rawValue else { return }
        if nsError.code == CLError.denied.rawValue {
            lastError = "위치 권한이 필요합니다."
            isUpdating = false
        } else {
            lastError = "위치 정보를 가져올 수 없어요."
        }
    }
}

extension CLLocationCoordinate2D {
    func distance(to other: CLLocationCoordinate2D) -> CLLocationDistance {
        let a = CLLocation(latitude: latitude, longitude: longitude)
        let b = CLLocation(latitude: other.latitude, longitude: other.longitude)
        return a.distance(from: b)
    }
}

// MARK: - Image Picker

struct CameraImagePicker: UIViewControllerRepresentable {
    enum Source { case camera, album }
    let source: Source
    var onPicked: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = source == .camera ? .camera : .photoLibrary
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPicked: (UIImage) -> Void

        init(onPicked: @escaping (UIImage) -> Void) {
            self.onPicked = onPicked
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                onPicked(image)
            }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Design Tokens

enum Brand {
    static let primary = Color(hex: "#2563EB")
    static let primary600 = Color(hex: "#1D4ED8")
    static let primary700 = Color(hex: "#1E40AF")
    static let blue50 = Color(hex: "#E6F2FF")
    static let blue100 = Color(hex: "#BFDBFE")
    static let price = Color(hex: "#16A34A")
    static let green50 = Color(hex: "#ECFDF5")
    static let indigo = Color(hex: "#4F46E5")
    static let amber = Color(hex: "#D97706")
    static let purple = Color(hex: "#8B5CF6")
    static let red = Color(hex: "#EF4444")
    static let gray50 = Color(hex: "#F8FAFC")
    static let gray100 = Color(hex: "#F1F5F9")
    static let gray200 = Color(hex: "#E2E8F0")
    static let gray300 = Color(hex: "#CBD5E1")
    static let gray500 = Color(hex: "#64748B")
    static let gray700 = Color(hex: "#334155")
    static let gray900 = Color(hex: "#0F172A")
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64

        switch hex.count {
        case 3:
            red = (int >> 8) * 17
            green = (int >> 4 & 0xF) * 17
            blue = (int & 0xF) * 17
            alpha = 255
        case 6:
            red = int >> 16
            green = int >> 8 & 0xFF
            blue = int & 0xFF
            alpha = 255
        case 8:
            red = int >> 16 & 0xFF
            green = int >> 8 & 0xFF
            blue = int & 0xFF
            alpha = int >> 24
        default:
            red = 0
            green = 0
            blue = 0
            alpha = 255
        }

        self.init(
            .sRGB,
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255,
            opacity: Double(alpha) / 255
        )
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

#if canImport(NMapsMap)
private extension PlaceCategory {
    var markerUIColor: UIColor {
        switch self {
        case .food:
            return UIColor(hex: "#EF4444")
        case .cafe:
            return UIColor(hex: "#8B5CF6")
        case .hair:
            return UIColor(hex: "#16A34A")
        case .lodging:
            return UIColor(hex: "#2563EB")
        }
    }
}

private extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)

        let red: UInt64
        let green: UInt64
        let blue: UInt64
        let alpha: UInt64

        switch hex.count {
        case 3:
            red = (int >> 8) * 17
            green = (int >> 4 & 0xF) * 17
            blue = (int & 0xF) * 17
            alpha = 255
        case 6:
            red = int >> 16
            green = int >> 8 & 0xFF
            blue = int & 0xFF
            alpha = 255
        case 8:
            red = int >> 16 & 0xFF
            green = int >> 8 & 0xFF
            blue = int & 0xFF
            alpha = int >> 24
        default:
            red = 0
            green = 0
            blue = 0
            alpha = 255
        }

        self.init(
            red: CGFloat(red) / 255,
            green: CGFloat(green) / 255,
            blue: CGFloat(blue) / 255,
            alpha: CGFloat(alpha) / 255
        )
    }
}
#endif
