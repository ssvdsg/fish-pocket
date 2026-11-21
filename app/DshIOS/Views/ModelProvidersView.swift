import SwiftUI

// MARK: - Provider rows

/// One provider as the 模型 page shows it: the configurable directory entry joined
/// with its settings namespace and credential states (`ModelsSettingsStore` in the web client).
struct ProviderRow: Identifiable, Hashable {
    let entry: JSON
    let active: Bool
    let configured: Bool
    let removable: Bool
    let apiKeyEnv: String?
    var credential: JSON?
    var derivedCredential: JSON?
    var credentialChecks: [String: JSON]?
    var accountAvailable: Bool?

    var id: String { provider }
    var provider: String { entry["provider"].string ?? "" }
    var settingsNs: String { entry["settingsNs"].string ?? "" }
    var settingsPath: [String] { entry["settingsPath"].array.compactMap(\.string) }
    var declared: Bool { entry["declared"].bool == true }
    var defaultBaseURL: String? { entry["defaultBaseURL"].string }
    var baseURLEnv: [String] { entry["baseURLEnv"].array.compactMap(\.string) }
    var nativeAuth: JSON? { entry["nativeAuth"].nonNull }
    var error: String? { entry["error"].string }
    var isAccount: Bool { provider == "deepseek-account" }

    var displayName: String {
        isAccount ? String(localized: "DeepSeek 账号") : (entry["displayName"].string ?? provider)
    }

    /// `显示名 (route)`, or the route alone when they are the same.
    var targetLabel: String { provider == displayName ? provider : "\(displayName) (\(provider))" }

    var credentialConfigured: Bool { credential?["configured"].bool == true }
    var credentialMissing: Bool { !credentialConfigured && apiKeyEnv != nil && credential?["configured"].bool == false }

    /// The page-managed credential a deletion removes with the provider.
    var managedCredential: String? {
        let managed = deriveKeyRef(provider)
        return apiKeyEnv == managed && credentialConfigured && credential?["writable"].bool == true ? managed : nil
    }

    /// Whether the row can serve requests as it stands (`providerUsable`).
    var usable: Bool {
        guard active else { return false }
        if isAccount { return accountAvailable == true }
        return apiKeyEnv == nil || credentialConfigured
    }
}

/// The conventional credential reference of a route: `moonshotai` → `MOONSHOTAI_API_KEY`.
func deriveKeyRef(_ provider: String) -> String {
    provider.uppercased().replacingOccurrences(of: "[^A-Z0-9]+", with: "_", options: .regularExpression) + "_API_KEY"
}

/// The joined provider rows, re-read whenever settings, credentials or adapters change.
@MainActor
@Observable
final class ModelProvidersModel {
    private(set) var rows: [ProviderRow] = []
    private(set) var loading = false
    private(set) var ready = false
    private(set) var error: String?
    private(set) var credentialError: String?

    func load(_ app: AppModel) async {
        loading = true
        defer { loading = false }
        do {
            async let registeredRead = app.client.call("llm/listProviders")
            async let directoryRead = app.client.call("llm/listConfigurableProviders")
            await app.settings.refresh(revision: app.settingsRevision)
            let (registered, directory) = try await (registeredRead, directoryRead)
            guard app.settings.loaded else {
                error = app.settings.error ?? String(localized: "加载提供商目录失败")
                return
            }
            let active = Set(registered.array.compactMap { $0["id"].string })
            let declared = Set(directory.array.compactMap { $0["provider"].string })
            var entries = directory.array
                .map { $0.setting(["active"], .bool(active.contains($0["provider"].string ?? ""))) }
            for provider in registered.array where !declared.contains(provider["id"].string ?? "") {
                entries.append(["provider": provider["id"], "displayName": provider["name"], "settingsNs": "", "settingsPath": [], "active": true])
            }
            func rank(_ entry: JSON) -> Int { entry["provider"].string == "deepseek-account" ? 0 : entry["provider"].string == "deepseek-official" ? 1 : 2 }
            entries = entries.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)

            var next = entries.map { entry -> ProviderRow in
                let namespace = app.settings.namespace(entry["settingsNs"].string ?? "")
                let path = entry["settingsPath"].array.compactMap(\.string)
                let profile = namespace?["value"].value(at: path)
                let isAccount = entry["provider"].string == "deepseek-account"
                let ref = profile?["apiKeyEnv"].string
                return ProviderRow(
                    entry: entry,
                    active: entry["active"].bool ?? false,
                    configured: namespace != nil && (path.isEmpty || profile != nil),
                    removable: namespace != nil && !path.isEmpty && namespace!["user"].has(path) && !namespace!["base"].has(path),
                    apiKeyEnv: isAccount ? nil : (ref?.isEmpty == false ? ref : nil)
                )
            }
            if next.contains(where: \.isAccount) {
                let catalog = try? await app.client.call("session/modelCatalog")
                let available = catalog?["groups"].array.contains { $0["id"].string == "deepseek-account" && !$0["models"].array.isEmpty } ?? false
                for index in next.indices where next[index].isAccount { next[index].accountAvailable = available }
            }
            let refs = next.filter { !$0.isAccount }.flatMap { row in
                row.apiKeyEnv.map { [$0] } ?? ([deriveKeyRef(row.provider)] + (row.nativeAuth?["env"].array.compactMap(\.string) ?? []))
            }
            var credentials: [String: JSON] = [:]
            credentialError = nil
            do {
                credentials = try await app.settings.describeCredentials(refs)
            } catch {
                credentialError = describeFailure(error)
            }
            rows = next.filter { !$0.isAccount || $0.accountAvailable == true }.map { row in
                guard !row.isAccount else { return row }
                var row = row
                if let ref = row.apiKeyEnv { row.credential = credentials[ref] } else { row.derivedCredential = credentials[deriveKeyRef(row.provider)] }
                if credentialError == nil {
                    let checked = row.apiKeyEnv.map { [$0] } ?? (row.nativeAuth?["env"].array.compactMap(\.string) ?? [])
                    row.credentialChecks = Dictionary(uniqueKeysWithValues: checked.compactMap { ref in credentials[ref].map { (ref, $0) } })
                }
                return row
            }
            error = nil
            ready = true
        } catch is CancellationError {
        } catch {
            self.error = describeFailure(error)
        }
    }
}

// MARK: - 模型 page

/// 设置 → 模型 (M-01…M-13): the default model, one row per configured provider with its
/// key state, an editor page per provider, and the add flow in a sheet of its own.
struct ModelProvidersPage: View {
    @Environment(AppModel.self) private var app
    @State private var model = ModelProvidersModel()
    @State private var deleteTarget: ProviderRow?
    @State private var deleting = false
    @State private var adding = false
    @State private var defaultModel: String?

    var body: some View {
        List {
            if app.settings.loaded, !app.settings.writable {
                Section { Text("设置当前为只读。").font(.footnote).foregroundStyle(Palette.waiting) }.groupedRow()
            }
            if let error = model.error, !model.ready {
                Section {
                    Text("加载提供商目录失败：\(error)").font(.footnote).foregroundStyle(Palette.removed)
                    Button("重试") { Task { await model.load(app) } }
                }
                .groupedRow()
            } else if !model.ready {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }.groupedRow()
            } else {
                if app.settings.serves("agent-default-model") {
                    Section {
                        NavigationLink {
                            NamespaceFormView(title: String(localized: "默认模型"), ns: "agent-default-model")
                        } label: {
                            LabeledContent("默认模型", value: defaultModel ?? "")
                        }
                    }
                    .groupedRow()
                }
                Section {
                    ForEach(configured) { row in providerRow(row) }
                } footer: {
                    Text("填入提供商的 API 密钥即可使用其模型。")
                }
                .groupedRow()
                Section {
                    Button { adding = true } label: {
                        Label("添加模型提供商", systemImage: "plus").foregroundStyle(Palette.ink)
                    }
                    .disabled(!app.settings.writable)
                }
                .groupedRow()
            }
        }
        .groupedList()
        .navigationTitle("模型")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) { AddProviderSheet(model: model) }
        .task(id: app.settingsRevision) {
            await model.load(app)
            await loadDefaultModel()
        }
        .refreshable { await app.settings.reload(); await model.load(app) }
        .alert(deleteTarget.map { String(localized: "删除 \($0.targetLabel)？") } ?? "", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }), presenting: deleteTarget) { target in
            Button("取消", role: .cancel) {}
            Button(String(localized: "删除 \(target.targetLabel)"), role: .destructive) { Task { await delete(target) } }
        } message: { target in
            Text(target.managedCredential != nil
                 ? "删除 \(target.targetLabel) 会移除其配置和存储的 API 密钥。"
                 : "删除 \(target.targetLabel) 会移除其配置。")
        }
    }

    private func loadDefaultModel() async {
        guard let value = try? await app.client.call("session/modelCatalog") else { return }
        let provider = value["default"]["provider"].string, id = value["default"]["model"].string
        let group = value["groups"].array.first { $0["id"].string == provider }
        defaultModel = group?["models"].array.first { $0["id"].string == id }?["name"].string ?? id
    }

    private var configured: [ProviderRow] { model.rows.filter(\.configured) }

    @ViewBuilder
    private func providerRow(_ row: ProviderRow) -> some View {
        let label = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(row.displayName).foregroundStyle(Palette.ink)
                if row.declared { PluginTag(text: String(localized: "自定义")) }
                Spacer(minLength: 8)
                if row.isAccount {
                    Text("已登录").font(.footnote).foregroundStyle(Palette.running)
                } else if row.credentialConfigured {
                    Text("已配置").font(.footnote).foregroundStyle(Palette.secondary)
                } else if row.credentialMissing {
                    Text("缺少密钥").font(.footnote).foregroundStyle(Palette.removed)
                }
            }
            if let error = row.error {
                Text(error).font(.caption).foregroundStyle(Palette.removed)
            }
        }
        if row.isAccount {
            label
        } else if let namespace = app.settings.namespace(row.settingsNs) {
            NavigationLink {
                ProviderEditorPage(model: model, row: row, namespace: namespace)
            } label: {
                label
            }
            .swipeActions {
                if row.removable, app.settings.writable {
                    Button("删除", role: .destructive) { deleteTarget = row }
                }
            }
        } else {
            label
        }
    }

    /// M-10: the managed credential first, so a failed second step stays retryable.
    private func delete(_ target: ProviderRow) async {
        guard !deleting else { return }
        deleting = true
        defer { deleting = false }
        do {
            if let ref = target.managedCredential { try await app.settings.unsetCredential(ref) }
            try await app.settings.mutate(target.settingsNs, [.unset(target.settingsPath)], expectedRevision: nil)
            await model.load(app)
        } catch {
            Haptics.error()
            app.showToast(describeFailure(error), duration: 5)
        }
    }
}

// MARK: - Validation

/// The first refused row of a `models` draft, as `模型 {n}: {reason}`. `only` names the levels
/// the route's protocol accepts, each sent under its own name; nil accepts any declared value.
private func modelFailure(_ value: JSON?, checkReasoning: Bool, only: [String]? = nil) -> String? {
    guard let value else { return nil }
    let models = value.array
    var seen = Set<String>()
    func failed(_ index: Int, _ reason: String) -> String { String(localized: "模型 \(index + 1): \(reason)") }
    for (index, model) in models.enumerated() {
        guard let id = model["id"].string?.trimmingCharacters(in: .whitespaces), !id.isEmpty else { return failed(index, String(localized: "模型 ID 不能为空。")) }
        if !seen.insert(id).inserted { return failed(index, String(localized: "模型 ID 不能重复。")) }
        if model.has(["name"]), (model["name"].string ?? "").isEmpty { return failed(index, String(localized: "显示名称不能为空。")) }
        if model.has(["contextWindow"]), !positiveInteger(model["contextWindow"]) { return failed(index, String(localized: "上下文窗口必须是正数，例如 131072、256K 或 1M。")) }
        if model.has(["maxTokens"]), !positiveInteger(model["maxTokens"]) { return failed(index, String(localized: "最大输出 token 数必须是正数，例如 8192、64K 或 1M。")) }
    }
    guard checkReasoning else { return nil }
    for (index, model) in models.enumerated() {
        guard model.has(["reasoningEfforts"]), model["reasoningEfforts"].bool != false else { continue }
        let entries = model["reasoningEfforts"].object
        if let only, entries.contains(where: { level, wire in !only.contains(level) || wire.string != level }) {
            return failed(index, levelsOnlyNotice)
        }
        let accepted = entries.allSatisfy { level, wire in
            if let text = wire.string { return !text.isEmpty }
            return wire.isNull && level == "off"
        }
        if !accepted { return failed(index, String(localized: "Off 以外的档位都需要填写 API 参数值，且参数值不能为空字符串。")) }
        if !entries.keys.contains(where: { $0 != "off" }) { return failed(index, String(localized: "至少添加一个 Off 以外的档位；不需要思考请关闭推理等级。")) }
    }
    return nil
}

private func positiveInteger(_ value: JSON) -> Bool {
    guard let number = value.double else { return false }
    return number.rounded() == number && number > 0
}

/// `256K`, `1M`, `131072`: nil when blank; a non-number stays in the draft as text, which validation refuses.
private func parseCapacity(_ text: String) -> JSON? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    guard let match = trimmed.range(of: #"^\d+(\.\d+)?[kKmM]?$"#, options: .regularExpression), match == trimmed.startIndex..<trimmed.endIndex else { return .string(trimmed) }
    let suffix = trimmed.last?.lowercased()
    let digits = suffix == "k" || suffix == "m" ? String(trimmed.dropLast()) : trimmed
    let scaled = (Double(digits) ?? 0) * (suffix == "k" ? 1000 : suffix == "m" ? 1_000_000 : 1)
    let rounded = scaled.rounded()
    return .number(abs(scaled - rounded) < 1e-6 ? rounded : scaled)
}

/// A stored count in the shortest form that reads back the same.
private func formatCapacity(_ value: Double) -> String {
    guard value.rounded() == value, value > 0 else { return String(value) }
    let count = Int(value)
    if count % 1_000_000 == 0 { return "\(count / 1_000_000)M" }
    if count % 1000 == 0 { return "\(count / 1000)K" }
    return String(count)
}

/// `validate`'s text for a typed key; nil allows submit (empty means keep the stored key).
private func apiKeyFailure(_ draft: String) -> String? {
    guard !draft.isEmpty else { return nil }
    let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.isEmpty { return String(localized: "请输入 API 密钥；留空则保持已存储的密钥。") }
    let illegal = String(localized: "该 API 密钥格式错误，请检查。")
    if value.range(of: "^[A-Z][A-Z0-9_]*=[^=]", options: .regularExpression) != nil { return illegal }
    if let first = value.first, "\"'`".contains(first), value.count > 1, value.last == first { return illegal }
    if value.range(of: #"^[\x21-\x7E]+$"#, options: .regularExpression) == nil { return illegal }
    return nil
}

// MARK: - Fields

/// The API key input: never reads a stored key back; an eye reveals what is typed
/// here, and any edit masks it again.
private struct APIKeyField: View {
    let placeholder: String
    @Binding var text: String
    @State private var revealed = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if revealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textContentType(nil)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.callout)
            if !text.isEmpty {
                Button { revealed.toggle() } label: {
                    Image(systemName: revealed ? "eye.slash" : "eye").foregroundStyle(Palette.secondary).hitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(revealed ? "隐藏密钥" : "显示密钥")
            }
        }
        .onChange(of: text) { _, _ in revealed = false }
    }
}

private struct DraftTextField: View {
    let title: LocalizedStringKey
    let placeholder: String
    let text: Binding<String>
    var keyboard: UIKeyboardType = .default

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Palette.secondary)
            TextField(placeholder, text: text, axis: .vertical)
                .keyboardType(keyboard)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout)
        }
    }
}

// MARK: - Provider editor

/// The curated fields of one adapter family.
private enum ProviderLayout {
    case deepseek, piAi, unknown

    init(_ ns: String) {
        switch ns {
        case "llm-deepseek": self = .deepseek
        case "llm-pi-ai": self = .piAi
        default: self = .unknown
        }
    }
}

/// A provider's editor pushed from its row (or from the add sheet's list).
private struct ProviderEditorPage: View {
    let model: ModelProvidersModel
    let row: ProviderRow
    let namespace: JSON
    var onAdded: (() -> Void)?

    var body: some View {
        ProviderEditor(model: model, row: row, namespace: namespace, onAdded: onAdded)
            .navigationTitle(row.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .keyboardDoneButton()
    }
}

/// One provider (M-03…M-09): the key, the model catalog and, behind 高级, address, identity
/// and retry policy. Edits stay local until 保存, which writes minimal path ops first and the
/// key second; a failure in the key step retries only that step. Adding splits the same card
/// in two: the key here, then 下一步 to the models, which saves.
private struct ProviderEditor: View {
    @Environment(AppModel.self) private var app
    let model: ModelProvidersModel
    let row: ProviderRow
    let namespace: JSON
    /// In the add flow: closes it after a save, instead of popping this page.
    var onAdded: (() -> Void)?

    private enum Failed { case settings, key }
    private static var failureAnchor: String { "provider-failure" }
    private static var keyAnchor: String { "provider-key" }

    @State private var draft: JSON = [:]
    @State private var original: JSON = [:]
    @State private var committed: JSON?
    @State private var expectedRevision: Int?
    @State private var keyDraft = ""
    @State private var busy = false
    @State private var failure: String?
    @State private var failedAt = Failed.settings
    @State private var attempts = 0
    @State private var prepared = false
    @State private var choosingModels = false
    @State private var saved = false

    private var adding: Bool { onAdded != nil }
    private var graph: SchemaGraph? { app.settings.graph(namespace["ns"].string ?? "") }
    private var path: [String] { row.settingsPath }
    private var layout: ProviderLayout { ProviderLayout(row.settingsNs) }
    private var fallback: JSON? { namespace["value"].value(at: path) }
    private var keyRef: String {
        if let named = fallback?["apiKeyEnv"].string, !named.isEmpty { return named }
        return deriveKeyRef(row.provider)
    }
    private var ownsIdentity: Bool { layout == .piAi && row.declared }
    /// The protocol the form shows, an edited-but-unsaved one included: it decides its own constraints.
    private var api: String? { stringAt(draft, "api") ?? stringAt(fallback, "api") }
    private var reasoning: (levels: [String], only: Bool) {
        guard ownsIdentity, let graph else { return ([], false) }
        return protocolReasoning(api, reasoningLevelChoices(graph))
    }
    private var protocols: [String] { graph.map(protocolChoices) ?? [] }
    private var keyValue: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var keyFailure: String? { apiKeyFailure(keyDraft) }
    /// A route whose protocol cannot authenticate without a key needs a key reference or a typed key.
    private var protocolKeyMissing: Bool {
        layout == .piAi && api == geminiProtocol && stringAt(draft, "apiKeyEnv") == nil && stringAt(fallback, "apiKeyEnv") == nil && keyValue.isEmpty
    }
    private var modelProblem: String? {
        let offered = reasoning
        // Inherited models are checked too where the protocol narrows their levels: switching an
        // inherited route's protocol must not write a route its own models break.
        let models = draft["models"].nonNull ?? (offered.only ? fallback?["models"].nonNull : nil)
        return modelFailure(models, checkReasoning: !offered.levels.isEmpty, only: offered.only ? offered.levels : nil)
    }
    /// The `retryPolicy` schema at this provider's path, with the policy beneath the user layer.
    private var retryShape: RetryPolicyShape? {
        guard layout != .unknown, let graph else { return nil }
        return RetryPolicyShape(graph: graph, path: path + ["retryPolicy"], base: namespace["base"])
    }
    private var retryProblem: RetryPolicyProblem? { retryShape?.problem(draft["retryPolicy"].nonNull) }
    private var disabled: Bool { busy || !app.settings.writable }
    private var dirty: Bool { prepared && (!keyDraft.isEmpty || draft != original) }
    private var canSave: Bool {
        !disabled && layout != .unknown && modelProblem == nil && retryProblem == nil && keyFailure == nil && !protocolKeyMissing
    }

    private func stringAt(_ source: JSON?, _ key: String) -> String? {
        guard let value = source?[key].string, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return value
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if layout == .unknown {
                    Section { Text("这个提供商不能在这里配置，可到「高级 → 配置文件」修改。").font(.footnote).foregroundStyle(Palette.secondary) }
                        .groupedRow()
                } else if graph?.node(at: path) == nil && !path.isEmpty {
                    Section { Text("\(row.displayName)：无法读取设置").font(.footnote).foregroundStyle(Palette.removed) }
                        .groupedRow()
                } else {
                    if failedAt == .settings { failureSection }
                    if !keylessNativeAuth { keySection }
                    if !adding {
                        catalogSection(autoFetch: false)
                        modelProblemSection
                    }
                    Section {
                        NavigationLink("高级") { advancedPage }
                        // 高级 hides the fields, so a refused policy still explains a disabled 保存.
                        if let retryProblem {
                            Text("重试策略：\(retryProblem.text)").font(.caption).foregroundStyle(Palette.removed)
                        }
                    }
                    .groupedRow()
                }
            }
            .onChange(of: attempts) { _, _ in
                withAnimation { proxy.scrollTo(failedAt == .key ? Self.keyAnchor : Self.failureAnchor, anchor: .center) }
            }
        }
        .inkTint()
        .groupedList()
        .scrollDismissesKeyboard(.interactively)
        .modifier(EditorChrome(adding: adding, dirty: dirty, canSave: canSave, canContinue: canContinue, busy: busy, next: { choosingModels = true }, save: { Task { await apply() } }))
        .navigationDestination(isPresented: $choosingModels) { modelsStep }
        .dismisses(when: saved)
        .task(id: row.provider) { prepare() }
    }

    /// 下一步 or 保存, by where the card is.
    private struct EditorChrome: ViewModifier {
        let adding: Bool
        let dirty: Bool
        let canSave: Bool
        let canContinue: Bool
        let busy: Bool
        let next: () -> Void
        let save: () -> Void

        func body(content: Content) -> some View {
            if adding {
                content
                    .interactiveDismissDisabled(dirty)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) { Button("下一步", action: next).disabled(!canContinue) }
                    }
            } else {
                content.editPage(dirty: dirty, canSave: canSave, saving: busy, save: save)
            }
        }
    }

    /// Adding, second step: the provider's models; 保存 ends the flow.
    private var modelsStep: some View {
        Form {
            failureSection
            catalogSection(autoFetch: true)
            modelProblemSection
        }
        .inkTint()
        .groupedList()
        .navigationTitle("选择模型")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .interactiveDismissDisabled(true)
        .saveToolbar(canSave: canSave, saving: busy) { Task { await apply() } }
    }

    @ViewBuilder
    private var failureSection: some View {
        if let failure {
            Section { Text(failure).font(.footnote).foregroundStyle(Palette.removed).id(Self.failureAnchor) }
                .groupedRow()
        }
    }

    @ViewBuilder
    private var modelProblemSection: some View {
        if let modelProblem {
            Section { Text(modelProblem).font(.footnote).foregroundStyle(Palette.waiting) }
                .groupedRow()
        }
    }

    /// The draft starts from the user layer: the card only names what it can see.
    private func prepare() {
        guard !prepared else { return }
        prepared = true
        let stored = namespace["user"].value(at: path)
        if case .object? = stored { draft = stored! } else { draft = [:] }
        // A stored retry policy without a mode edits under the mode it inherits; the draft
        // names it, so a saved policy always carries one.
        if case .object = draft["retryPolicy"], draft["retryPolicy"]["mode"].isNull, let retryShape {
            draft = draft.setting(["retryPolicy", "mode"], .string(retryShape.defaultMode))
        }
        original = draft
        committed = stored
        expectedRevision = namespace["revision"].int
    }

    // MARK: Credential

    private var namedRef: String? { stringAt(fallback, "apiKeyEnv") }
    private var nativeAuth: JSON? { namedRef == nil ? row.nativeAuth : nil }
    private var authRefs: [String] {
        if let namedRef { return [namedRef] }
        let env = nativeAuth?["env"].array.compactMap(\.string) ?? []
        return env.filter { !row.baseURLEnv.contains($0) }
    }
    /// A native route authenticated by OAuth alone has nothing to type.
    private var keylessNativeAuth: Bool {
        guard let nativeAuth else { return false }
        return nativeAuth["env"].array.isEmpty && nativeAuth["oauth"].bool == true
    }
    private var checked: [(ref: String, info: JSON?)] {
        authRefs.map { ref in (ref, row.credentialChecks?[ref] ?? (ref == namedRef ? row.credential : nil)) }
    }
    private var detected: (ref: String, info: JSON?)? { checked.first { $0.info?["configured"].bool == true } }
    private var keyPlaceholder: String {
        detected != nil ? String(localized: "已配置，留空不修改") : String(localized: "输入 API 密钥")
    }

    /// Adding: on to the models once the provider can authenticate (OAuth routes need no key).
    private var keyNeeded: Bool {
        !keylessNativeAuth && !authRefs.isEmpty && detected == nil && keyValue.isEmpty && nativeAuth?["oauth"].bool != true
    }
    private var canContinue: Bool { !disabled && layout != .unknown && keyFailure == nil && !keyNeeded && retryProblem == nil }

    private var keySection: some View {
        Section {
            APIKeyField(placeholder: keyPlaceholder, text: $keyDraft).disabled(disabled).id(Self.keyAnchor)
            if let keyFailure { Text(keyFailure).font(.caption).foregroundStyle(Palette.removed) }
            if failedAt == .key, let failure { Text(failure).font(.caption).foregroundStyle(Palette.removed) }
        } header: {
            Text("API 密钥")
        } footer: {
            // A key the protocol requires is a requirement still to meet, not a fault.
            if (adding && keyNeeded) || protocolKeyMissing { Text("填入 API 密钥后继续。") }
        }
        .groupedRow()
    }

    // MARK: Customized

    private func setField(_ key: String, _ text: String) {
        let value = text.trimmingCharacters(in: .whitespaces)
        draft = draft.setting([key], value.isEmpty ? nil : .string(text))
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(get: { stringAt(draft, key) ?? draft[key].string ?? "" }, set: { setField(key, $0) })
    }

    private var baseURLPlaceholder: String {
        if layout == .deepseek { return "https://api.deepseek.com/anthropic" }
        return stringAt(fallback, "baseURL") ?? row.defaultBaseURL ?? String(localized: "填写 API 地址")
    }

    /// 高级: what a provider rarely needs changed; staged with the card.
    private var advancedPage: some View {
        Form {
            Section {
                if ownsIdentity {
                    DraftTextField(title: "显示名称", placeholder: row.provider, text: textBinding("displayName")).disabled(disabled)
                }
                DraftTextField(title: "API 地址", placeholder: baseURLPlaceholder, text: textBinding("baseURL"), keyboard: .URL).disabled(disabled)
                if ownsIdentity {
                    let current = api
                    Picker("API 协议", selection: Binding(get: { current ?? "" }, set: { setField("api", $0) })) {
                        if current == nil { Text("未选择").tag("") }
                        ForEach(protocols, id: \.self) { Text(protocolLabel($0)).tag($0) }
                    }
                    .disabled(disabled)
                }
            } footer: {
                if layout == .deepseek { Text("需兼容 Anthropic Messages 协议。") }
            }
            .groupedRow()
            retrySection
        }
        .inkTint()
        .groupedList()
        .navigationTitle("高级")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
    }

    /// 重试策略 on a page of its own, staged with the card like the fields above it. The page
    /// keeps what it shows; every change lands in the draft.
    @ViewBuilder
    private var retrySection: some View {
        if let shape = retryShape {
            Section {
                NavigationLink {
                    RetryPolicyPage(
                        policy: draft["retryPolicy"].nonNull,
                        shape: shape,
                        disabled: disabled,
                        update: { next in draft = draft.setting(["retryPolicy"], next) }
                    )
                } label: {
                    LabeledContent("重试策略", value: shape.summary(draft["retryPolicy"].nonNull))
                }
                if let retryProblem { Text(retryProblem.text).font(.caption).foregroundStyle(Palette.removed) }
            }
            .groupedRow()
        }
    }

    // MARK: Catalog

    private var modelsOverridden: Bool { draft.has(["models"]) }

    /// The catalog beneath the user layer: what the composition pinned, or the schema default.
    private var inheritedModels: [JSON] {
        namespace["base"].value(at: path + ["models"])?.array ?? graph?.node(at: path + ["models"])?.defaultValue?.array ?? []
    }

    private var models: [JSON] { modelsOverridden ? draft["models"].array : inheritedModels }

    private func catalogSection(autoFetch: Bool) -> some View {
        ModelCatalogSection(
            models: models,
            overridden: modelsOverridden,
            autoFetch: autoFetch,
            family: layout == .deepseek ? .deepseek : .piAi,
            defaultContextWindow: fallback?["defaultContextWindow"].double,
            defaultMaxTokens: fallback?["maxTokens"].double,
            defaultInput: fallback?["defaultInput"].array.compactMap(\.string),
            reasoningLevels: reasoning.levels,
            reasoningLevelsOnly: reasoning.only,
            disabled: disabled,
            probe: layout == .piAi ? ModelProbe(
                settingsNs: row.settingsNs,
                provider: row.provider,
                baseURL: stringAt(draft, "baseURL") ?? stringAt(fallback, "baseURL"),
                api: api,
                apiKey: keyValue.isEmpty ? nil : keyValue,
                blocked: keyFailure ?? (protocolKeyMissing ? String(localized: "填入 API 密钥后继续。") : nil)
            ) : nil,
            loadCatalog: layout == .piAi && !row.declared,
            onChange: { draft = draft.setting(["models"], .array($0)) },
            onReset: { draft = draft.setting(["models"], nil) }
        )
    }

    // MARK: Saving

    private func apply() async {
        busy = true
        failure = nil
        defer { busy = false }
        if let problem = await applyOnce() {
            failure = problem.text
            failedAt = problem.at
            // The add flow's key is a step back.
            if problem.at == .key { choosingModels = false }
            attempts += 1
            Haptics.error()
            return
        }
        Haptics.success()
        // Close first: a fresh list drops this provider from what can be added.
        if let onAdded { onAdded() } else { saved = true }
        await model.load(app)
        app.showToast(String(localized: "已保存 \(row.targetLabel)。"))
    }

    /// Settings first (minimal path ops, fenced by the card's revision), then the key.
    private func applyOnce() async -> (text: String, at: Failed)? {
        let ns = row.settingsNs
        var next = draft
        if layout == .piAi, stringAt(draft, "apiKeyEnv") == nil, stringAt(fallback, "apiKeyEnv") == nil, !keyValue.isEmpty {
            next = next.setting(["apiKeyEnv"], .string(keyRef))
        }
        let offered = reasoning
        if let problem = modelFailure(next["models"].nonNull, checkReasoning: !offered.levels.isEmpty, only: offered.only ? offered.levels : nil) { return (problem, .settings) }
        let materializes = layout == .piAi && fallback == nil && committed == nil && next.object.isEmpty
        let ops: [SettingsOp] = materializes ? [.set(path, [:])] : pathOps(base: path, before: committed, after: next)
        if !ops.isEmpty {
            do {
                let written = try await app.settings.mutate(ns, ops, expectedRevision: expectedRevision)
                committed = written["user"].value(at: path)
                expectedRevision = written["revision"].int
                draft = next
                original = next
            } catch {
                return (isConflict(error)
                    ? String(localized: "这些设置已在别处改动。请返回后重新打开，在当前值上编辑。")
                    : describeFailure(error), .settings)
            }
        }
        if !keyValue.isEmpty {
            do {
                try await app.settings.setCredential(keyRef, keyValue)
            } catch {
                return (describeFailure(error), .key)
            }
            keyDraft = ""
        }
        return nil
    }
}

/// The minimal ops carrying `after` over `before`: only keys the card observed are named.
/// Objects are diffed field by field, so a field the draft leaves out is unset back to what
/// it inherits instead of being dropped by a whole-object set.
private func pathOps(base: [String], before: JSON?, after: JSON) -> [SettingsOp] {
    let previous = before?.object ?? [:]
    var ops: [SettingsOp] = []
    for (key, value) in after.object.sorted(by: { $0.key < $1.key }) where previous[key] != value {
        switch (value, previous[key]) {
        case (.object, .object?), (.object, nil): ops += pathOps(base: base + [key], before: previous[key], after: value)
        default: ops.append(.set(base + [key], value))
        }
    }
    for key in previous.keys.sorted() where after.object[key] == nil {
        ops.append(.unset(base + [key]))
    }
    return ops
}

/// The wire protocols a hand-declared route may name, read from the namespace's own schema.
private func protocolChoices(_ graph: SchemaGraph) -> [String] {
    guard let node = graph.node(at: ["providers", "\0probe", "api"]), node.type == "union" else { return [] }
    return graph.list(node).compactMap { $0.json["value"].string }
}

/// The reasoning levels a hand-declared model may declare, in the schema's escalation order.
private func reasoningLevelChoices(_ graph: SchemaGraph) -> [String] {
    guard let node = graph.node(at: ["providers", "\0probe", "models", "0", "reasoningEfforts"]) else { return [] }
    let dict = graph.list(node).first { $0.type == "dict" }
    guard let key = dict.map({ graph.node($0.json["sKey"]) }) else { return [] }
    return graph.list(key).compactMap { $0.json["value"].string }
}

private func protocolLabel(_ value: String) -> String {
    switch value {
    case "openai-completions": "OpenAI Chat Completions"
    case "openai-responses": "OpenAI Responses"
    case "anthropic-messages": "Anthropic Messages"
    case geminiProtocol: "Gemini API"
    default: value
    }
}

/// pi-ai's Gemini protocol. Its implementation refuses a request without an API key, which
/// no header or ambient credential replaces, so the forms ask for one before a write: the
/// adapter accepts the profile and only the first request would fail.
private let geminiProtocol = "google-generative-ai"

/// The reasoning levels a protocol's models may declare, narrowed from the schema's. pi-ai's
/// Gemini protocol sends only minimal, low, medium or high and fails a request carrying
/// anything else, so a Gemini route offers those four, each under its own name, and no Off.
private func protocolReasoning(_ api: String?, _ levels: [String]) -> (levels: [String], only: Bool) {
    guard api == geminiProtocol else { return (levels, false) }
    return (levels.filter { ["minimal", "low", "medium", "high"].contains($0) }, true)
}

/// What a model row outside the levels its protocol accepts is told, on the row and at the save.
private var levelsOnlyNotice: String {
    String(localized: "此 API 协议仅接受 minimal、low、medium 和 high 档位，且每个档位的 API 参数值须与档位名称相同。请修改或删除其他档位。")
}

// MARK: - Retry policy

/// A refused drafted policy: the reason and the field that causes it.
private struct RetryPolicyProblem {
    let text: String
    let path: [String]
}

/// A provider's `retryPolicy` schema and the policy beneath the user layer, read as the web
/// card reads them: each union branch is a mode, a branch's fields are the inputs, and their
/// bounds and defaults come from the schema.
private struct RetryPolicyShape {
    let graph: SchemaGraph
    /// The mode branches, in schema order.
    let branches: [(mode: String, node: SchemaNode)]
    /// The policy the composition layer sets, if any.
    let inherited: JSON?

    /// Nil when the namespace publishes no `retryPolicy` union of mode branches at `path`.
    init?(graph: SchemaGraph, path: [String], base: JSON) {
        guard let node = graph.node(at: path), node.type == "union" else { return nil }
        let branches = graph.list(node).compactMap { branch -> (mode: String, node: SchemaNode)? in
            guard let mode = graph.fields(branch).first(where: { $0.key == "mode" })?.node.json["value"].string else { return nil }
            return (mode, branch)
        }
        guard !branches.isEmpty else { return nil }
        self.graph = graph
        self.branches = branches
        inherited = base.value(at: path)
    }

    var modes: [String] { branches.map(\.mode) }

    /// The mode in effect while the user layer names none.
    var defaultMode: String {
        if let mode = inherited?["mode"].string, branch(mode) != nil { return mode }
        return branches[0].mode
    }

    /// The branch of a stored `mode`; nil when no branch declares it.
    func branch(_ mode: String?) -> SchemaNode? {
        branches.first { $0.mode == mode }?.node
    }

    /// An object's editable fields in schema order, without the `mode` discriminant.
    func fields(_ node: SchemaNode) -> [(key: String, node: SchemaNode)] {
        graph.fields(node).filter { $0.key != "mode" }
    }

    /// The inherited value of one field of a branch: the composition layer, then the schema default.
    func inheritedValue(_ branch: SchemaNode, _ path: [String]) -> JSON? {
        inherited?.value(at: path) ?? graph.node(at: path, from: branch)?.defaultValue
    }

    /// The constant choices a code list's item schema publishes, in schema order.
    func choices(_ node: SchemaNode) -> [String] {
        graph.list(graph.inner(node)).filter { $0.type == "const" }.compactMap { $0.json["value"].string }
    }

    /// The row's value: the chosen mode, or the default named by the mode it inherits.
    func summary(_ policy: JSON?) -> String {
        let mode = policy?["mode"].string
        return branch(mode) == nil ? String(localized: "默认（\(retryLabel(defaultMode))）") : retryLabel(mode ?? "")
    }

    /// The first refused field of a drafted policy, empty fields inherited: the bounds of the
    /// chosen branch's number fields, then the delay order `resolveRetryPolicy` enforces beyond
    /// any single bound. Whatever else the schema refuses is answered by the write.
    func problem(_ policy: JSON?) -> RetryPolicyProblem? {
        guard let policy, let chosen = branch(policy["mode"].string) else { return nil }
        func read(_ path: [String]) -> JSON? { policy.value(at: path) ?? inheritedValue(chosen, path) }
        func check(_ owner: SchemaNode, _ base: [String]) -> RetryPolicyProblem? {
            for field in fields(owner) {
                let path = base + [field.key]
                if field.node.type == "object" {
                    if let nested = check(field.node, path) { return nested }
                } else if field.node.type == "number", let value = read(path), let text = retryNumberProblem(field.node, value) {
                    return RetryPolicyProblem(text: text, path: path)
                }
            }
            return nil
        }
        if let found = check(chosen, []) { return found }
        let initial = ["backoff", "initialDelayMs"]
        if let lower = read(initial)?.double, let upper = read(["backoff", "maxDelayMs"])?.double, lower > upper {
            return RetryPolicyProblem(text: String(localized: "初始延迟不能大于最大延迟。"), path: initial)
        }
        return nil
    }
}

/// The first bound of a number field's schema that `value` breaks.
private func retryNumberProblem(_ node: SchemaNode, _ value: JSON) -> String? {
    guard let number = value.double else { return String(localized: "请填数字；留空表示使用默认值。") }
    if node.meta["step"].double == 1, number.rounded() != number { return String(localized: "请填整数。") }
    if let minimum = node.meta["min"].double {
        // `Number.MIN_VALUE` is the schema's idiom for a positive bound.
        if minimum == .leastNonzeroMagnitude {
            if number <= 0 { return String(localized: "必须大于 0。") }
        } else if number < minimum {
            return String(localized: "不能小于 \(retryNumberText(.number(minimum)))。")
        }
    }
    if let maximum = node.meta["max"].double, number > maximum {
        return String(localized: "不能大于 \(retryNumberText(.number(maximum)))。")
    }
    return nil
}

/// Typed text as a field's value: plain decimal text is a number, and anything else stays in
/// the draft as text, which validation refuses.
private func retryNumber(_ text: String) -> JSON {
    // A decimal pad types the region's own separator, a comma in much of the world.
    let separator = Locale.current.decimalSeparator ?? "."
    let plain = separator == "." ? text : text.replacingOccurrences(of: separator, with: ".")
    guard plain.range(of: #"^[+-]?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$"#, options: .regularExpression) != nil,
          let number = Double(plain), number.isFinite else { return .string(text) }
    return .number(number)
}

/// A drafted or inherited value as its field shows it.
private func retryNumberText(_ value: JSON?) -> String {
    if let number = value?.double { return Int(exactly: number).map(String.init) ?? String(number) }
    return value?.string ?? ""
}

/// A copy of `policy` with `value` at `path`; nil removes the field, and with it any parent left empty.
private func retrySetting(_ policy: JSON, _ path: [String], _ value: JSON?) -> JSON {
    guard let key = path.first else { return policy }
    let rest = Array(path.dropFirst())
    var object = policy.object
    let next: JSON? = rest.isEmpty ? value : retrySetting(policy[key], rest, value)
    object[key] = next == JSON.object([:]) ? nil : next
    return .object(object)
}

/// The names of the known modes and fields, by schema key; any other key shows as it is.
private func retryLabel(_ key: String) -> String {
    switch key {
    case "normal": String(localized: "仅临时错误")
    case "always": String(localized: "所有错误")
    case "maxRetries": String(localized: "最大重试次数")
    case "retryableCodes": String(localized: "错误码")
    case "backoff": String(localized: "退避")
    case "initialDelayMs": String(localized: "初始延迟（毫秒）")
    case "maxDelayMs": String(localized: "最大延迟（毫秒）")
    case "jitterRatio": String(localized: "抖动比例")
    default: key
    }
}

/// The names of the known failure codes; a code without one shows as it is.
private func retryCodeLabel(_ code: String) -> String {
    switch code {
    case "EMPTY_RESPONSE": String(localized: "空响应")
    case "RATE_LIMIT": String(localized: "请求限流")
    case "SERVER": String(localized: "服务器错误")
    case "TIMEOUT": String(localized: "超时")
    case "TRANSPORT": String(localized: "网络错误")
    case "STREAM_CLOSED": String(localized: "流提前结束")
    case "MALFORMED_RESPONSE": String(localized: "响应格式错误")
    case "QUOTA": String(localized: "配额已用尽")
    default: code
    }
}

/// 重试策略: the mode and, once one is chosen, its fields. No policy inherits; a chosen mode
/// writes a user-layer policy whose empty fields keep the inherited values.
private struct RetryPolicyPage: View {
    @State var policy: JSON?
    let shape: RetryPolicyShape
    let disabled: Bool
    let update: (JSON?) -> Void

    /// Raw text per field, so partial input such as `0.` stays as typed.
    @State private var texts: [String: String] = [:]
    /// Codes added during this edit stay listed after they are switched off.
    @State private var added: [String: [String]] = [:]

    private var branch: SchemaNode? { shape.branch(policy?["mode"].string) }
    private var mode: String? { branch == nil ? nil : policy?["mode"].string }
    private var problem: RetryPolicyProblem? { shape.problem(policy) }

    private func write(_ next: JSON?) {
        policy = next
        update(next)
    }

    var body: some View {
        Form {
            Section {
                Picker("模式", selection: Binding(get: { mode ?? "" }, set: { selectMode($0) })) {
                    Text("默认（\(retryLabel(shape.defaultMode))）").tag("")
                    ForEach(shape.modes, id: \.self) { Text(retryLabel($0)).tag($0) }
                }
                .pickerValueTint()
            } footer: {
                if mode == "always" { Text("失败的请求会持续重试，直到成功或本轮被停止。") }
            }
            .groupedRow()
            if let branch { fieldSections(branch) }
        }
        .inkTint()
        .groupedList()
        .disabled(disabled)
        .navigationTitle("重试策略")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
    }

    /// A branch's fields in schema order: a number as a row, the code list as switches, a
    /// nested object as a section of its numbers. Fields of other types are not shown.
    @ViewBuilder
    private func fieldSections(_ branch: SchemaNode) -> some View {
        ForEach(shape.fields(branch), id: \.key) { field in
            switch field.node.type {
            case "number":
                Section { numberRow([field.key], field.node, branch) }.groupedRow()
            case "array":
                codeSection([field.key], field.node, branch)
            case "object":
                Section {
                    ForEach(shape.fields(field.node).filter { $0.node.type == "number" }, id: \.key) { nested in
                        numberRow([field.key, nested.key], nested.node, branch)
                    }
                } header: {
                    Text(retryLabel(field.key))
                }
                .groupedRow()
            default:
                EmptyView()
            }
        }
    }

    /// One number: empty keeps the inherited value, which shows as the placeholder.
    @ViewBuilder
    private func numberRow(_ path: [String], _ node: SchemaNode, _ branch: SchemaNode) -> some View {
        let id = path.joined(separator: ".")
        LabeledContent(retryLabel(path.last ?? "")) {
            TextField(retryNumberText(shape.inheritedValue(branch, path)), text: Binding(
                get: { texts[id] ?? retryNumberText(policy?.value(at: path)) },
                set: { setNumber(path, $0) }
            ))
            .keyboardType(node.meta["step"].double == 1 ? .numberPad : .decimalPad)
            .multilineTextAlignment(.trailing)
        }
        if let problem, problem.path == path {
            Text(problem.text).font(.caption).foregroundStyle(Palette.removed)
        }
    }

    private func setNumber(_ path: [String], _ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        texts[path.joined(separator: ".")] = trimmed.isEmpty ? "" : text
        // An emptied field is unset, so the inherited value applies again.
        write(retrySetting(policy ?? [:], path, trimmed.isEmpty ? nil : retryNumber(trimmed)))
    }

    private func selectMode(_ mode: String) {
        texts = [:]
        guard let next = shape.branch(mode) else {
            write(nil)
            return
        }
        // A switched policy keeps only the fields its new mode declares.
        let declared = Set(shape.fields(next).map(\.key))
        var kept = (policy?.object ?? [:]).filter { declared.contains($0.key) }
        kept["mode"] = .string(mode)
        write(.object(kept))
    }

    // MARK: Codes

    /// The codes switched on: the drafted list, or the inherited one while the field is unset.
    private func selectedCodes(_ path: [String], _ inherited: [String]) -> [String] {
        guard case .array(let stored)? = policy?.value(at: path) else { return inherited }
        return stored.compactMap(\.string)
    }

    /// The codes on offer: the schema's own, then any inherited, drafted or just-added one outside them.
    private func codeChoices(_ id: String, _ node: SchemaNode, _ inherited: [String], _ selected: [String]) -> [String] {
        var seen = Set<String>()
        let listed: [String] = shape.choices(node) + inherited + selected
        return (listed + (added[id] ?? [])).filter { seen.insert($0).inserted }
    }

    @ViewBuilder
    private func codeSection(_ path: [String], _ node: SchemaNode, _ branch: SchemaNode) -> some View {
        let id = path.joined(separator: ".")
        let inherited = shape.inheritedValue(branch, path)?.array.compactMap(\.string) ?? []
        let selected = selectedCodes(path, inherited)
        let choices = codeChoices(id, node, inherited, selected)
        Section {
            ForEach(choices, id: \.self) { code in
                let isOn = selected.contains(code)
                Toggle(retryCodeLabel(code), isOn: Binding(get: { isOn }, set: { on in
                    selectCodes(path, choices.filter { $0 == code ? on : selected.contains($0) }, inherited)
                }))
                // A policy retries at least one code.
                .disabled(selected.count == 1 && isOn)
            }
            HStack {
                TextField("自定义错误码", text: Binding(get: { texts[id] ?? "" }, set: { texts[id] = $0 }))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.callout.monospaced())
                    .onSubmit { addCode(path, selected, inherited) }
                Button { addCode(path, selected, inherited) } label: { Text("添加").hitTarget() }
                    .buttonStyle(.borderless)
                    .disabled((texts[id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text(retryLabel(path.last ?? ""))
        }
        .groupedRow()
    }

    private func selectCodes(_ path: [String], _ next: [String], _ inherited: [String]) {
        // Exactly the inherited codes keep the field inherited.
        let inherits = next.count == inherited.count && next.allSatisfy { inherited.contains($0) }
        write(retrySetting(policy ?? [:], path, inherits ? nil : .array(next.map(JSON.string))))
    }

    private func addCode(_ path: [String], _ selected: [String], _ inherited: [String]) {
        let id = path.joined(separator: ".")
        let code = (texts[id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !code.isEmpty else { return }
        if added[id]?.contains(code) != true { added[id, default: []].append(code) }
        texts[id] = ""
        // A code already listed is switched on, not listed twice.
        if !selected.contains(code) { selectCodes(path, selected + [code], inherited) }
    }
}

// MARK: - Model catalog

/// What the 获取可用模型 call asks: the endpoint the form currently shows, a key typed but
/// unsaved included, so adding a provider is one pass.
struct ModelProbe {
    let settingsNs: String
    var provider: String?
    var baseURL: String?
    var api: String?
    var apiKey: String?
    /// The form's failure that blocks asking.
    var blocked: String?

    var request: JSON {
        var object: [String: JSON] = [:]
        if let provider { object["provider"] = .string(provider) }
        if let baseURL, !baseURL.isEmpty { object["baseURL"] = .string(baseURL) }
        if let api { object["api"] = .string(api) }
        if let apiKey { object["apiKey"] = .string(apiKey) }
        return .object(object)
    }

    var askable: Bool { provider != nil || (baseURL?.isEmpty == false) }
}

private enum CatalogFamily { case deepseek, piAi }

/// M-07: the model rows, their reset, add and fetch actions (M-13).
private struct ModelCatalogSection: View {
    @Environment(AppModel.self) private var app
    let models: [JSON]
    /// nil: a new custom API, which has no inherited catalog to speak of.
    let overridden: Bool?
    /// Adding: an empty list asks the provider as soon as it shows.
    var autoFetch = false
    let family: CatalogFamily
    let defaultContextWindow: Double?
    let defaultMaxTokens: Double?
    let defaultInput: [String]?
    let reasoningLevels: [String]
    /// The route's protocol accepts only `reasoningLevels`, each sent under its own name.
    let reasoningLevelsOnly: Bool
    let disabled: Bool
    let probe: ModelProbe?
    let loadCatalog: Bool
    let onChange: ([JSON]) -> Void
    let onReset: () -> Void

    @State private var fetching = false
    @State private var failure: String?
    @State private var candidates: [JSON]?
    @State private var inputDefaults: [String: [String]] = [:]
    @State private var autoFetched = false

    private var inputField: String { family == .deepseek ? "inputModalities" : "input" }

    var body: some View {
        Section {
            if let overridden {
                LabeledContent("模型列表", value: overridden ? String(localized: "已自定义") : String(localized: "默认"))
                    .resettable(overridden && !disabled, title: "恢复默认模型", reset: onReset)
            }
            if models.isEmpty {
                Text("还没有模型。").font(.footnote).foregroundStyle(Palette.secondary)
            }
            ForEach(Array(models.enumerated()), id: \.offset) { index, model in
                NavigationLink {
                    ModelRowEditor(
                        model: model,
                        position: index + 1,
                        inputField: inputField,
                        inputFallback: inputDefaults[model["id"].string ?? ""] ?? defaultInput,
                        contextHint: family == .deepseek ? defaultContextWindow.map(formatCapacity) ?? String(localized: "使用提供商默认值") : "256K",
                        tokensHint: family == .deepseek ? defaultMaxTokens.map(formatCapacity) ?? String(localized: "使用提供商默认值") : "32K",
                        reasoningLevels: reasoningLevels,
                        reasoningLevelsOnly: reasoningLevelsOnly,
                        disabled: disabled,
                        update: { next in onChange(models.enumerated().map { $0.offset == index ? next : $0.element }) },
                        remove: { onChange(models.enumerated().filter { $0.offset != index }.map(\.element)) }
                    )
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model["id"].string.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "未填写模型 ID"))
                            .font(.callout.monospaced()).foregroundStyle(Palette.ink).lineLimit(1)
                        if let name = model["name"].string, !name.isEmpty {
                            Text(name).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                        }
                    }
                }
                .swipeActions {
                    Button("删除模型", role: .destructive) { onChange(models.enumerated().filter { $0.offset != index }.map(\.element)) }
                }
            }
            Button {
                onChange(models + [["id": ""]])
            } label: {
                Label("添加模型", systemImage: "plus").foregroundStyle(Palette.ink)
            }
            .disabled(disabled)
            .sheet(isPresented: Binding(get: { candidates != nil }, set: { if !$0 { candidates = nil } })) {
                ModelPickerSheet(candidates: candidates ?? [], known: Set(models.compactMap { $0["id"].string }), adopt: adopt)
            }
            .task(id: loadCatalog ? probe?.provider : nil) { await readInputDefaults() }
            if let probe {
                Button {
                    Task { await fetch(probe) }
                } label: {
                    HStack(spacing: 8) {
                        if fetching { ProgressView().controlSize(.small) }
                        Text(fetching ? "正在获取…" : "获取可用模型").foregroundStyle(Palette.ink)
                    }
                }
                .disabled(disabled || fetching || !probe.askable || probe.blocked != nil)
                if !probe.askable {
                    Text("请先填写 API 地址，再获取。").font(.caption).foregroundStyle(Palette.secondary)
                } else if let blocked = probe.blocked {
                    Text(blocked).font(.caption).foregroundStyle(Palette.waiting)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(Palette.removed) }
        } header: {
            Text("模型")
        } footer: {
            if overridden == true { Text("在「模型列表」上左滑可恢复默认。") }
            else if overridden == nil && models.isEmpty { Text("至少添加一个模型才能保存。") }
        }
        .groupedRow()
        .task {
            guard autoFetch, !autoFetched, models.isEmpty, let probe, probe.askable, probe.blocked == nil else { return }
            autoFetched = true
            await fetch(probe)
        }
    }

    /// A catalog route's input types: what its own listing says, shown as each row's default.
    private func readInputDefaults() async {
        guard loadCatalog, let probe, let provider = probe.provider else { return }
        do {
            let found = try await app.client.call("llm/discoverModels", ["settingsNs": .string(probe.settingsNs), "request": ["provider": .string(provider)]])
            remember(found.array)
        } catch {
            failure = describeFailure(error)
        }
    }

    private func remember(_ found: [JSON]) {
        for candidate in found {
            if let id = candidate["id"].string, !candidate["inputModalities"].isNull {
                inputDefaults[id] = candidate["inputModalities"].array.compactMap(\.string)
            }
        }
    }

    private func fetch(_ probe: ModelProbe) async {
        fetching = true
        failure = nil
        defer { fetching = false }
        do {
            let found = try await app.client.call("llm/discoverModels", ["settingsNs": .string(probe.settingsNs), "request": probe.request]).array
            if loadCatalog { remember(found) }
            if found.isEmpty {
                failure = String(localized: "该提供商没有列出任何模型，请手动添加。")
            } else {
                candidates = found
            }
        } catch {
            failure = describeFailure(error)
        }
    }

    /// Picked ids join the rows; a row already there keeps the user's values.
    private func adopt(_ picked: [JSON]) {
        var rows = models
        for candidate in picked {
            guard let id = candidate["id"].string, !rows.contains(where: { $0["id"].string == id }) else { continue }
            var row: [String: JSON] = ["id": .string(id)]
            if let name = candidate["name"].string { row["name"] = .string(name) }
            if !candidate["contextWindow"].isNull { row["contextWindow"] = candidate["contextWindow"] }
            if !candidate["maxTokens"].isNull { row["maxTokens"] = candidate["maxTokens"] }
            if !candidate["inputModalities"].isNull { row["input"] = candidate["inputModalities"] }
            rows.append(.object(row))
        }
        onChange(rows)
        candidates = nil
    }
}

/// One model of the catalog: id, name, capacities, input types and, on hand-declared
/// routes, its reasoning levels. Fields it does not show stay in the row.
private struct ModelRowEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var model: JSON
    let position: Int
    let inputField: String
    let inputFallback: [String]?
    let contextHint: String
    let tokensHint: String
    let reasoningLevels: [String]
    let reasoningLevelsOnly: Bool
    let disabled: Bool
    let update: (JSON) -> Void
    let remove: () -> Void

    @State private var contextText = ""
    @State private var tokensText = ""

    private func write(_ next: JSON) {
        model = next
        update(next)
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(get: { model[key].string ?? "" }, set: { write(model.setting([key], $0.isEmpty ? (key == "id" ? .string("") : nil) : .string($0))) })
    }

    var body: some View {
        Form {
            Section {
                DraftTextField(title: "模型 ID", placeholder: "", text: field("id"))
                DraftTextField(title: "显示名称", placeholder: String(localized: "留空时使用模型 ID"), text: field("name"))
            }
            .groupedRow()
            Section("模型选项") {
                DraftTextField(title: "上下文窗口", placeholder: contextHint, text: Binding(get: { contextText }, set: { contextText = $0; write(model.setting(["contextWindow"], parseCapacity($0))) }))
                DraftTextField(title: "最大输出 token 数", placeholder: tokensHint, text: Binding(get: { tokensText }, set: { tokensText = $0; write(model.setting(["maxTokens"], parseCapacity($0))) }))
                inputTypes
            }
            .groupedRow()
            if !reasoningLevels.isEmpty { ReasoningEditor(model: model, levels: reasoningLevels, levelsOnly: reasoningLevelsOnly, write: write) }
            Section {
                Button("删除模型", role: .destructive) { remove(); dismiss() }
            }
            .groupedRow()
        }
        .inkTint()
        .groupedList()
        .disabled(disabled)
        .navigationTitle(String(localized: "模型 \(position)"))
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .onAppear {
            contextText = model["contextWindow"].double.map(formatCapacity) ?? model["contextWindow"].string ?? ""
            tokensText = model["maxTokens"].double.map(formatCapacity) ?? model["maxTokens"].string ?? ""
        }
        .onDisappear {
            let id = model["id"].string ?? ""
            let trimmed = id.trimmingCharacters(in: .whitespaces)
            if trimmed != id { write(model.setting(["id"], .string(trimmed))) }
        }
    }

    private var selected: [String] {
        let list = model[inputField].array.compactMap(\.string)
        return list.isEmpty ? (inputFallback ?? ["text"]) : list
    }

    private var inputTypes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("输入类型").font(.caption).foregroundStyle(Palette.secondary)
            ForEach(["text", "image"], id: \.self) { modality in
                let isOn = selected.contains(modality)
                Toggle(modality == "text" ? "文本" : "图片", isOn: Binding(get: { isOn }, set: { on in
                    let next = ["text", "image"].filter { $0 == modality ? on : selected.contains($0) }
                    var row = model.setting([inputField], .array(next.map(JSON.string)))
                    if inputField == "inputModalities" && !next.contains("image") {
                        row = row.setting(["imagePixelBudget"], nil).setting(["imageMaxBytes"], nil)
                    }
                    write(row)
                }))
                .disabled(selected.count == 1 && isOn)
            }
        }
    }
}

/// M-08: the levels a hand-declared model offers, each with the wire value it sends.
private struct ReasoningEditor: View {
    let model: JSON
    let levels: [String]
    /// The route's protocol accepts only `levels`, each sent under its own name.
    let levelsOnly: Bool
    let write: (JSON) -> Void

    private var entries: [String: JSON]? {
        guard model.has(["reasoningEfforts"]), model["reasoningEfforts"].bool != false else { return nil }
        return model["reasoningEfforts"].object
    }

    private func order(_ level: String) -> Int { levels.firstIndex(of: level) ?? levels.count }
    private func defaultValue(_ level: String) -> JSON { level == "off" ? .null : .string(level) }

    /// A stored level the offered ones do not name stays selectable in its own row.
    private func choices(for level: String, used: [String]) -> [String] {
        (levels.contains(level) ? [] : [level]) + levels.filter { $0 == level || !used.contains($0) }
    }

    private func set(_ next: [String: JSON]?) {
        write(model.setting(["reasoningEfforts"], next.map(JSON.object)))
    }

    var body: some View {
        Section {
            Toggle("推理等级", isOn: Binding(get: { entries != nil }, set: { on in
                let initial = ["off", "low", "medium", "high"].filter(levels.contains)
                set(on ? Dictionary(uniqueKeysWithValues: initial.map { ($0, defaultValue($0)) }) : nil)
            }))
            if let entries {
                // Levels the protocol does not offer share one rank, so their names order them.
                let used = entries.keys.sorted { (order($0), $0) < (order($1), $1) }
                ForEach(used, id: \.self) { level in
                    HStack(spacing: 8) {
                        Picker("档位", selection: Binding(get: { level }, set: { to in
                            var next = entries
                            let wire = next.removeValue(forKey: level)
                            // A protocol that fixes its levels sends each under its own name, so nothing carries over.
                            let keeps = !levelsOnly && wire?.string.map { !$0.isEmpty && $0 != level } == true && level != "off" && to != "off"
                            next[to] = keeps ? wire : defaultValue(to)
                            set(next)
                        })) {
                            ForEach(choices(for: level, used: used), id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        TextField(level == "off" ? String(localized: "关闭思考") : String(localized: "API 参数值"), text: Binding(
                            get: { entries[level]?.string ?? "" },
                            set: { text in
                                var next = entries
                                let trimmed = text.trimmingCharacters(in: .whitespaces)
                                next[level] = trimmed.isEmpty ? defaultValue(level) : .string(trimmed)
                                set(next)
                            }
                        ))
                        .font(.callout.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(level == "off" || levelsOnly)
                        Button {
                            var next = entries
                            next[level] = nil
                            set(next)
                        } label: {
                            Image(systemName: "minus.circle").foregroundStyle(Palette.secondary).hitTarget()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除档位")
                    }
                }
                if levelsOnly, entries.contains(where: { level, wire in !levels.contains(level) || wire.string != level }) {
                    Text(levelsOnlyNotice).font(.caption).foregroundStyle(Palette.removed)
                }
                if levels.contains(where: { !used.contains($0) }) {
                    Button {
                        let highest = used.compactMap { levels.firstIndex(of: $0) }.max() ?? -1
                        let level = levels.enumerated().first { $0.offset > highest && !used.contains($0.element) }?.element ?? levels.first { !used.contains($0) }
                        if let level {
                            var next = entries
                            next[level] = defaultValue(level)
                            set(next)
                        }
                    } label: {
                        Label("添加档位", systemImage: "plus").foregroundStyle(Palette.ink)
                    }
                }
            }
        } footer: {
            Text("参数值写入请求的推理强度字段，默认与档位名相同。Off 表示关闭思考。")
        }
        .groupedRow()
    }
}

/// M-13: pick from what the provider lists: 全选 takes the visible rows, 取消全选 clears all.
private struct ModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let candidates: [JSON]
    let known: Set<String>
    let adopt: ([JSON]) -> Void
    @State private var query = ""
    @State private var picked: Set<String> = []
    @State private var prepared = false

    private var visible: [JSON] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return candidates }
        return candidates.filter { candidate in
            (candidate["id"].string ?? "").lowercased().contains(needle) || (candidate["name"].string ?? "").lowercased().contains(needle)
        }
    }

    private var allVisiblePicked: Bool { !visible.isEmpty && visible.allSatisfy { picked.contains($0["id"].string ?? "") } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if visible.isEmpty { Text("没有匹配的模型。").foregroundStyle(Palette.secondary) }
                    ForEach(visible, id: \.self) { candidate in
                        let id = candidate["id"].string ?? ""
                        Button {
                            if !picked.insert(id).inserted { picked.remove(id) }
                            Haptics.select()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: picked.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(id) ? Palette.ink : Palette.faint)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(id).font(.footnote.monospaced()).foregroundStyle(Palette.ink).lineLimit(1)
                                    if let name = candidate["name"].string, name != id {
                                        Text(name).font(.caption).foregroundStyle(Palette.secondary).lineLimit(1)
                                    }
                                }
                            }
                        }
                    }
                } header: {
                    Text("以下是模型提供商的可用模型，勾选要添加的模型。").textCase(nil)
                }
                .groupedRow()
            }
            .groupedList()
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索模型")
            .navigationTitle("选择要添加的模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { adopt(candidates.filter { picked.contains($0["id"].string ?? "") }) }
                        .disabled(picked.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(allVisiblePicked ? "取消全选" : "全选") {
                        if allVisiblePicked { picked = [] } else { picked.formUnion(visible.map { $0["id"].string ?? "" }) }
                    }
                }
            }
            .onAppear {
                guard !prepared else { return }
                prepared = true
                picked = Set(candidates.compactMap { $0["id"].string }.filter { !known.contains($0) })
            }
        }
        .inkTint()
    }
}

// MARK: - Adding

/// M-11: pick a provider from the catalog or declare a custom API; either way the key
/// comes first, then the models. The list is read once: saving moves a provider out of
/// what can be added, and the page it pushed must survive a failed key step.
private struct AddProviderSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: ModelProvidersModel
    @State private var addable: [ProviderRow]?

    private var piAi: JSON? { app.settings.namespace("llm-pi-ai") }
    private var protocols: [String] { app.settings.graph("llm-pi-ai").map(protocolChoices) ?? [] }

    var body: some View {
        NavigationStack {
            List {
                if let addable {
                    Section("选择提供商") {
                        if addable.isEmpty {
                            Text("目录中的提供商都已添加。").font(.footnote).foregroundStyle(Palette.secondary)
                        }
                        ForEach(addable) { row in
                            if let namespace = app.settings.namespace(row.settingsNs) {
                                NavigationLink(row.displayName) {
                                    ProviderEditorPage(model: model, row: row, namespace: namespace, onAdded: { dismiss() })
                                }
                            }
                        }
                    }
                    .groupedRow()
                }
                if let piAi {
                    Section {
                        NavigationLink("自定义 API") {
                            CustomProviderForm(model: model, namespace: piAi, protocols: protocols, reasoningLevels: app.settings.graph("llm-pi-ai").map(reasoningLevelChoices) ?? [], onAdded: { dismiss() })
                                .navigationTitle("自定义 API")
                                .navigationBarTitleDisplayMode(.inline)
                                .keyboardDoneButton()
                        }
                    } footer: {
                        Text("中转站、自部署服务等兼容 OpenAI、Anthropic 或 Gemini 协议的接口。")
                    }
                    .groupedRow()
                }
            }
            .groupedList()
            .navigationTitle("添加模型提供商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
            }
        }
        .inkTint()
        .sheetNotices()
        .onAppear {
            if addable == nil { addable = model.rows.filter { !$0.configured && app.settings.serves($0.settingsNs) } }
        }
    }
}

/// M-12: declare a custom model API (writes `llm-pi-ai`, then the key). First the address
/// and key, then the models it lists. The provider ID is derived from the name or the
/// address; 高级 can name it.
private struct CustomProviderForm: View {
    @Environment(AppModel.self) private var app
    let model: ModelProvidersModel
    let namespace: JSON
    let protocols: [String]
    let reasoningLevels: [String]
    let onAdded: () -> Void

    @State private var routeDraft = ""
    @State private var displayName = ""
    @State private var baseURL = ""
    @State private var api = ""
    @State private var keyDraft = ""
    @State private var models: [JSON] = []
    @State private var busy = false
    @State private var failure: String?
    /// The profile write landed under this ID; only the key can still be outstanding.
    @State private var committedRoute: String?
    @State private var openedAt: Int?
    @State private var choosingModels = false

    private var route: String { committedRoute ?? (routeDraft.isEmpty ? derivedRoute : routeDraft) }
    private var derivedRoute: String {
        func slug(_ text: String) -> String {
            text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        let host = URLComponents(string: normalizedURL)?.host?.replacingOccurrences(of: #"^(api|www)\."#, with: "", options: .regularExpression)
        var base = slug(displayName)
        if base.isEmpty { base = slug(host?.split(separator: ".").first.map(String.init) ?? "") }
        if base.first?.isLetter != true { base = base.isEmpty ? "custom" : "custom-\(base)" }
        let taken = Set(model.rows.map(\.provider))
        var candidate = base, suffix = 2
        while taken.contains(candidate) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }
        return candidate
    }
    private var routeValid: Bool { route.range(of: "^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$", options: .regularExpression) != nil }
    private var routeTaken: Bool { committedRoute == nil && model.rows.contains { $0.provider == route } }
    private var normalizedURL: String { baseURL.trimmingCharacters(in: .whitespaces) }
    private var urlInvalid: Bool {
        guard !baseURL.isEmpty else { return false }
        guard let scheme = URLComponents(string: normalizedURL)?.scheme?.lowercased(), URLComponents(string: normalizedURL)?.host?.isEmpty == false else { return true }
        return scheme != "http" && scheme != "https"
    }
    private var keyFailure: String? { apiKeyFailure(keyDraft) }
    private var keyValue: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// A blank key is a choice only where the protocol can authenticate without one.
    private var keyMissing: Bool { api == geminiProtocol && keyValue.isEmpty }
    private var reasoning: (levels: [String], only: Bool) { protocolReasoning(api, reasoningLevels) }
    private var modelProblem: String? { modelFailure(.array(models), checkReasoning: true, only: reasoning.only ? reasoning.levels : nil) }
    private var canContinue: Bool { routeValid && !routeTaken && !normalizedURL.isEmpty && !urlInvalid && keyFailure == nil && !keyMissing }
    private var ready: Bool { canContinue && !models.isEmpty && modelProblem == nil }
    private var locked: Bool { busy || committedRoute != nil || !app.settings.writable }
    private var dirty: Bool { !baseURL.isEmpty || !keyDraft.isEmpty || !displayName.isEmpty || !routeDraft.isEmpty }

    var body: some View {
        Form {
            Section {
                DraftTextField(title: "API 地址", placeholder: baseURLExample, text: $baseURL, keyboard: .URL).disabled(locked)
                if urlInvalid { Text("请输入有效的 HTTP 或 HTTPS 地址。").font(.caption).foregroundStyle(Palette.removed) }
                Picker("API 协议", selection: $api) {
                    ForEach(protocols, id: \.self) { Text(protocolLabel($0)).tag($0) }
                }
                .disabled(locked)
            }
            .groupedRow()
            Section {
                APIKeyField(placeholder: String(localized: "输入 API 密钥"), text: $keyDraft).disabled(busy)
                if let keyFailure { Text(keyFailure).font(.caption).foregroundStyle(Palette.removed) }
            } header: {
                Text("API 密钥")
            } footer: {
                if normalizedURL.isEmpty { Text("填写 API 地址后继续。") } else if keyMissing { Text("填入 API 密钥后继续。") }
            }
            .groupedRow()
            Section {
                NavigationLink {
                    advancedPage
                } label: {
                    LabeledContent("高级", value: displayName.isEmpty ? route : displayName)
                }
                if routeTaken { Text("已有提供商使用了这个 ID。").font(.caption).foregroundStyle(Palette.removed) }
            }
            .groupedRow()
        }
        .inkTint()
        .groupedList()
        .scrollDismissesKeyboard(.interactively)
        .interactiveDismissDisabled(dirty)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("下一步") { choosingModels = true }.disabled(!canContinue) }
        }
        .navigationDestination(isPresented: $choosingModels) { modelsStep }
        .onAppear {
            if api.isEmpty { api = protocols.first ?? "" }
            if openedAt == nil { openedAt = namespace["revision"].int }
        }
    }

    /// The endpoint each protocol's SDK expects: Anthropic's appends `/v1/messages` itself,
    /// and Gemini's base carries the API version.
    private var baseURLExample: String {
        switch api {
        case "anthropic-messages": "https://gateway.example"
        case geminiProtocol: "https://gateway.example/v1beta"
        default: "https://gateway.example/v1"
        }
    }

    private var advancedPage: some View {
        Form {
            Section {
                DraftTextField(title: "显示名称", placeholder: route, text: $displayName).disabled(locked)
                DraftTextField(title: "提供商 ID", placeholder: derivedRoute, text: $routeDraft).disabled(locked)
                if !routeDraft.isEmpty && !routeValid {
                    Text("以小写字母开头，可用小写字母、数字和短横线。").font(.caption).foregroundStyle(Palette.removed)
                } else if routeTaken {
                    Text("已有提供商使用了这个 ID。").font(.caption).foregroundStyle(Palette.removed)
                }
            } footer: {
                Text("留空时根据地址自动生成。")
            }
            .groupedRow()
        }
        .inkTint()
        .groupedList()
        .navigationTitle("高级")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
    }

    private var modelsStep: some View {
        Form {
            if let failure {
                Section { Text(failure).font(.footnote).foregroundStyle(Palette.removed) }.groupedRow()
            }
            ModelCatalogSection(
                models: models,
                overridden: nil,
                autoFetch: true,
                family: .piAi,
                defaultContextWindow: nil,
                defaultMaxTokens: nil,
                defaultInput: nil,
                reasoningLevels: reasoning.levels,
                reasoningLevelsOnly: reasoning.only,
                disabled: locked,
                probe: ModelProbe(
                    settingsNs: "llm-pi-ai",
                    baseURL: normalizedURL.isEmpty ? nil : normalizedURL,
                    api: api.isEmpty ? nil : api,
                    apiKey: keyValue.isEmpty ? nil : keyValue,
                    blocked: urlInvalid ? String(localized: "请输入有效的 HTTP 或 HTTPS 地址。") : keyFailure
                ),
                loadCatalog: false,
                onChange: { models = $0 },
                onReset: {}
            )
            if !models.isEmpty, let modelProblem {
                Section { Text(modelProblem).font(.footnote).foregroundStyle(Palette.waiting) }.groupedRow()
            }
        }
        .inkTint()
        .groupedList()
        .navigationTitle("选择模型")
        .navigationBarTitleDisplayMode(.inline)
        .keyboardDoneButton()
        .interactiveDismissDisabled(true)
        .saveToolbar(canSave: ready && !busy && app.settings.writable, saving: busy) { Task { await create() } }
    }

    private func create() async {
        busy = true
        failure = nil
        defer { busy = false }
        let target = route
        let keyRef = deriveKeyRef(target)
        if committedRoute == nil {
            var profile: [String: JSON] = ["api": .string(api), "baseURL": .string(normalizedURL), "models": .array(models)]
            if !displayName.isEmpty { profile["displayName"] = .string(displayName) }
            if !keyValue.isEmpty { profile["apiKeyEnv"] = .string(keyRef) }
            do {
                try await app.settings.mutate("llm-pi-ai", [.set(["providers", target], .object(profile))], expectedRevision: openedAt)
                committedRoute = target
            } catch {
                failure = isConflict(error)
                    ? String(localized: "这些设置已在别处改动。请返回后重新打开，在当前值上编辑。")
                    : describeFailure(error)
                Haptics.error()
                return
            }
        }
        if !keyValue.isEmpty {
            do {
                try await app.settings.setCredential(keyRef, keyValue)
            } catch {
                failure = describeFailure(error)
                Haptics.error()
                return
            }
        }
        Haptics.success()
        onAdded()
        await model.load(app)
        app.showToast(String(localized: "已保存 \(displayName.isEmpty ? target : displayName)。"))
    }
}
