import SwiftUI

struct ServerAddressDraft {
    var name = ""
    var host = ""
    var path = ""
    var port = ""
    var usesHTTPS = true
    var showsPassword = false

    init(address: String = "", name: String = "", defaultPort: String = "") {
        self.name = name
        port = defaultPort
        guard let parts = URLComponents(string: address), parts.host != nil else { return }
        host = parts.host ?? ""
        path = parts.path == "/" ? "" : parts.path
        port = parts.port.map(String.init) ?? ""
        usesHTTPS = parts.scheme?.lowercased() == "https"
    }

    mutating func absorbPastedAddress() {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.contains("://"), let parts = URLComponents(string: value),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let parsedHost = parts.host, parts.user == nil, parts.password == nil else { return }
        host = parsedHost
        path = parts.path == "/" ? "" : parts.path
        port = parts.port.map(String.init) ?? ""
        usesHTTPS = parts.scheme?.lowercased() == "https"
    }

    var address: String? {
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanHost.contains("://"),
              !cleanHost.contains(where: { $0.isWhitespace }),
              !cleanHost.contains("/"), !cleanHost.contains("@"),
              !cleanHost.contains("?"), !cleanHost.contains("#") else { return nil }
        let cleanPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanPort.isEmpty || Int(cleanPort).map({ (1...65535).contains($0) }) == true else { return nil }
        var parts = URLComponents()
        parts.scheme = usesHTTPS ? "https" : "http"
        parts.host = cleanHost
        parts.port = Int(cleanPort)
        parts.path = cleanPath.isEmpty ? "/" : (cleanPath.hasPrefix("/") ? cleanPath : "/" + cleanPath)
        return parts.url?.absoluteString
    }
}



struct StorageConnectionEditor: View {
    enum Kind { case smb, webDAV }
    @EnvironmentObject private var library: LibraryStore
    @StateObject private var discovery = SMBDiscovery()
    let kind: Kind
    var existingID: UUID? = nil
    let close: () -> Void
    @State private var name = ""
    @State private var host = ""
    @State private var path = ""
    @State private var port = "443"
    @State private var https = true
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var share = ""
    @State private var syncAllowed = true
    @State private var showPassword = false
    @State private var loaded = false
    @State private var passwordLoaded = false
    @State private var shares: [String] = []
    @State private var checking = false
    @State private var shareRequest = UUID()
    @State private var error: String?
    private var title: String { (existingID == nil ? "添加 " : "编辑 ") + (kind == .smb ? "SMB" : "WebDAV") }
    private var valid: Bool {
        !name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && !host.isEmpty &&
        (kind == .smb ? !share.isEmpty : address != nil)
    }
    private var address: String? {
        let rawPort = port.trimmingCharacters(in:.whitespacesAndNewlines)
        guard rawPort.isEmpty || (Int(rawPort).map { (1...65535).contains($0) } == true) else { return nil }
        var value = URLComponents(); value.scheme = https ? "https" : "http"
        value.host = host.trimmingCharacters(in:.whitespacesAndNewlines)
        value.port = Int(rawPort)
        let trimmed = path.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.split(separator:"/").contains("..") else { return nil }
        value.path = trimmed.isEmpty ? "/" : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
        return value.url?.absoluteString
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing:22) {
                    LucentFormField("名称") { TextField("必填",text:$name) }
                    LucentFormField("同步") { Toggle("允许云端同步",isOn:$syncAllowed) }
                    if kind == .webDAV {
                        LucentFormField("协议") { Toggle("HTTPS",isOn:$https) }
                    }
                    LucentFormField("服务器地址") { TextField("必填（127.0.0.1 / sample.com）",text:$host).lucentURLInput() }
                    if kind == .webDAV {
                        LucentFormField("端口号") { TextField(https ? "443" : "80",text:$port).lucentTimeInput() }
                    }
                    LucentFormField("用户名") { TextField("选填，留空以访客身份登录",text:$username).textContentType(.username) }
                    LucentFormField("密码") {
                        LucentPasswordInput(text: $password, visible: $showPassword, placeholder: "选填").privacySensitive()
                    }
                    if kind == .webDAV {
                        LucentFormField("路径") { TextField("选填（默认 /）",text:$path) }
                    } else {
                        LucentFormField("域名") { TextField("选填",text:$domain) }
                        LucentFormField("共享名称") { TextField("必填，也可从下方选择",text:$share) }
                        VStack(alignment:.leading,spacing:9) {
                            HStack {
                                Text("可用的共享").font(.system(size:15,weight:.semibold)).foregroundStyle(.secondary)
                                Spacer()
                                Button { findShares() } label: {
                                    if checking { ProgressView().controlSize(.small) } else { Text("查找") }
                                }.disabled(host.isEmpty || checking)
                            }.padding(.horizontal,15)
                            if !shares.isEmpty {
                                VStack(spacing:0) {
                                    ForEach(shares,id:\.self) { value in
                                        Button { share = value } label: {
                                            HStack { Text(value); Spacer(); Image(systemName:share == value ? "checkmark" : "chevron.right") }
                                                .padding(18).contentShape(Rectangle())
                                        }.buttonStyle(.plain)
                                    }
                                }.background(LucentUI.panel,in:RoundedRectangle(cornerRadius:24))
                            }
                            ForEach(discovery.hosts,id:\.self) { server in
                                Button { host = server; findShares() } label: {
                                    HStack { Text(server); Spacer(); Image(systemName:"chevron.right").foregroundStyle(.secondary) }
                                        .padding(18).frame(maxWidth:.infinity)
                                        .background(LucentUI.panel,in:RoundedRectangle(cornerRadius:24))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red).frame(maxWidth:.infinity,alignment:.leading) }
                }.padding(.horizontal,20).padding(.top,24).padding(.bottom,32)
            }
            .background(LucentUI.page)
            .lucentTextInput().autocorrectionDisabled()
            .navigationTitle(title).lucentNavigationTitleStyle()
            .toolbar {
                LucentEditorToolbar(actionTitle: existingID == nil ? "添加" : "保存", canSave: valid, close: close, save: save)
            }
            .tint(LucentUI.selectionTint)
            #if !os(tvOS)
            .toggleStyle(SwitchToggleStyle(tint: LucentUI.switchTint))
            #endif
            .onChange(of:https) { old,new in if port == (old ? "443" : "80") { port = new ? "443" : "80" } }
            .onChange(of:host) { _,value in absorb(value) }
            .onAppear {
                guard !loaded else { return }; loaded = true
                if kind == .smb { discovery.start() }
                guard let id = existingID else { name = kind == .smb ? "我的 SMB" : "我的 WebDAV"; return }
                if kind == .smb, let source = library.smbSources.first(where: { $0.id == id }) {
                    name = source.name; host = source.host; share = source.share; username = source.username
                    domain = source.domain ?? ""; syncAllowed = source.syncAllowed != false
                    if let value = try? KeychainPasswordStore.get(for:id) { password = value; passwordLoaded = true }
                } else if let source = library.webDAVSources.first(where: { $0.id == id }) {
                    name = source.name; username = source.username; syncAllowed = source.syncAllowed != false
                    absorb(source.baseAddress)
                    if let value = try? KeychainPasswordStore.webDAVPassword(for:id) { password = value; passwordLoaded = true }
                }
            }
            .onDisappear { discovery.stop() }
        }
    }
    private func absorb(_ value: String) {
        guard value.contains("://"), let url = URLComponents(string:value), url.user == nil, url.password == nil,
              let server = url.host, ["smb","http","https"].contains(url.scheme?.lowercased() ?? "") else { return }
        host = server
        if kind == .webDAV { https = url.scheme == "https"; port = url.port.map(String.init) ?? (https ? "443" : "80"); path = url.path }
        else if !url.path.isEmpty { share = url.path.trimmingCharacters(in:CharacterSet(charactersIn:"/")) }
    }
    private func findShares() {
        let server = host, user = username, secret = password, realm = domain
        checking = true; error = nil; shares = []
        let request = UUID(); shareRequest = request
        Task {
            defer { if shareRequest == request { checking = false } }
            do {
                let values = try await Task.detached(priority:.userInitiated) { try SMBScanner.shares(host:server,username:user,password:secret,domain:realm) }.value
                guard shareRequest == request, host == server, username == user, password == secret, domain == realm else { return }
                shares = values
            }
            catch { if shareRequest == request { self.error = "无法读取共享，请检查地址与登录信息。可手动填写共享名称。" } }
        }
    }
    private func save() {
        let secret: String? = existingID == nil || passwordLoaded || !password.isEmpty ? password : nil
        let success: Bool
        if kind == .smb {
            success = library.saveSMBConnection(id:existingID,name:name,host:host,share:share,username:username,
                domain:domain,password:secret,syncAllowed:syncAllowed)
        } else if let address {
            success = library.saveWebDAVConnection(id:existingID,name:name,address:address,username:username,
                password:secret,syncAllowed:syncAllowed)
        } else { error = "请检查服务器地址、端口和路径。"; return }
        if success { close() } else { error = library.errorMessage ?? "保存失败"; library.errorMessage = nil }
    }
}
