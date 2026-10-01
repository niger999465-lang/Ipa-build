import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model

struct Rule: Identifiable, Codable {
    var id = UUID()
    var name: String
    var destPath: String      // đường dẫn tương đối trong Documents, vd: "Data/config.bytes"
    var replacement: String   // tên file thay thế đã được copy vào app
    var applied = false
}

enum PatchError: LocalizedError {
    case badPath, missingReplacement
    var errorDescription: String? {
        switch self {
        case .badPath: return "Đường dẫn không hợp lệ (không dùng .. hoặc để trống)."
        case .missingReplacement: return "Không tìm thấy file thay thế."
        }
    }
}

// MARK: - Paths

enum Paths {
    static let fm = FileManager.default
    static var docs: URL { fm.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func support(_ sub: String) -> URL {
        let u = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Patcher").appendingPathComponent(sub)
        try? fm.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var replacements: URL { support("Replacements") }
    static var backups: URL { support("Backups") }
    static var rulesFile: URL { support("").appendingPathComponent("rules.json") }
}

// MARK: - Patcher (logic)

enum Patcher {
    static let fm = FileManager.default

    static func dest(for rule: Rule) throws -> URL {
        let parts = rule.destPath.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(".."), !parts.contains(".") else { throw PatchError.badPath }
        return parts.reduce(Paths.docs) { $0.appendingPathComponent($1) }
    }

    static func apply(_ rule: Rule) throws {
        let dest = try dest(for: rule)
        let src = Paths.replacements.appendingPathComponent(rule.replacement)
        guard fm.fileExists(atPath: src.path) else { throw PatchError.missingReplacement }

        let bdir = Paths.backups.appendingPathComponent(rule.id.uuidString)
        if !fm.fileExists(atPath: bdir.path) {           // chỉ sao lưu 1 lần, giữ bản gốc thật
            try fm.createDirectory(at: bdir, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                try fm.copyItem(at: dest, to: bdir.appendingPathComponent("original"))
            } else {
                fm.createFile(atPath: bdir.appendingPathComponent("none").path, contents: nil)
            }
        }
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
    }

    static func restore(_ rule: Rule) throws {
        let dest = try dest(for: rule)
        let bdir = Paths.backups.appendingPathComponent(rule.id.uuidString)
        let original = bdir.appendingPathComponent("original")
        if fm.fileExists(atPath: original.path) {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: original, to: dest)
        } else if fm.fileExists(atPath: bdir.appendingPathComponent("none").path) {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        }
        try? fm.removeItem(at: bdir)
    }
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var rules: [Rule] = [] { didSet { save() } }
    @Published var error: String?

    init() {
        if let d = try? Data(contentsOf: Paths.rulesFile),
           let r = try? JSONDecoder().decode([Rule].self, from: d) { rules = r }
    }
    private func save() {
        try? JSONEncoder().encode(rules).write(to: Paths.rulesFile)
    }

    func set(_ rule: Rule, on: Bool) {
        guard let i = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        do {
            if on { try Patcher.apply(rules[i]) } else { try Patcher.restore(rules[i]) }
            rules[i].applied = on
        } catch { self.error = error.localizedDescription }
    }

    func delete(at offsets: IndexSet) {
        for i in offsets where rules[i].applied { try? Patcher.restore(rules[i]) }
        rules.remove(atOffsets: offsets)
    }
}

// MARK: - UI

@main
struct FilePatcherApp: App {
    @StateObject private var store = Store()
    var body: some Scene {
        WindowGroup { RulesView().environmentObject(store) }
    }
}

struct RulesView: View {
    @EnvironmentObject var store: Store
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.rules) { rule in
                    Toggle(isOn: Binding(
                        get: { rule.applied },
                        set: { store.set(rule, on: $0) })
                    ) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name).font(.headline)
                            Text("Documents/\(rule.destPath)")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete(perform: store.delete)
            }
            .overlay { if store.rules.isEmpty { Text("Chưa có rule nào").foregroundStyle(.secondary) } }
            .navigationTitle("File Patcher")
            .toolbar { Button { showAdd = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showAdd) { AddRuleView().environmentObject(store) }
            .alert("Lỗi", isPresented: Binding(
                get: { store.error != nil }, set: { _ in store.error = nil })
            ) { Button("OK", role: .cancel) {} } message: { Text(store.error ?? "") }
        }
    }
}

struct AddRuleView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var destPath = ""
    @State private var pickedName: String?
    @State private var showPicker = false
    @State private var ruleID = UUID()

    var body: some View {
        NavigationStack {
            Form {
                Section("Tên") { TextField("Tên rule", text: $name) }
                Section("Đích (trong Documents)") {
                    TextField("vd: Data/config.bytes", text: $destPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("File thay thế") {
                    Button(pickedName ?? "Chọn file…") { showPicker = true }
                }
            }
            .navigationTitle("Rule mới")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Huỷ") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Lưu") {
                        guard let f = pickedName else { return }
                        store.rules.append(Rule(id: ruleID, name: name.isEmpty ? f : name,
                                                destPath: destPath, replacement: f))
                        dismiss()
                    }.disabled(pickedName == nil || destPath.isEmpty)
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.item]) { result in
                guard case .success(let url) = result else { return }
                let ok = url.startAccessingSecurityScopedResource()
                defer { if ok { url.stopAccessingSecurityScopedResource() } }
                let stored = "\(ruleID.uuidString)-\(url.lastPathComponent)"
                let to = Paths.replacements.appendingPathComponent(stored)
                try? FileManager.default.removeItem(at: to)
                do { try FileManager.default.copyItem(at: url, to: to); pickedName = stored }
                catch { store.error = error.localizedDescription }
            }
        }
    }
}
