import AppKit
import SwiftUI

@_silgen_name("mb_snapshot") func rawSnapshot() -> UnsafeMutablePointer<CChar>?

func readMetrics() -> [String: Any] {
    guard let ptr = rawSnapshot() else { return [:] }
    defer { free(ptr) }
    return (try? JSONSerialization.jsonObject(with: Data(String(cString: ptr).utf8))) as? [String: Any] ?? [:]
}
func number(_ d: [String: Any], _ key: String) -> Double? { (d[key] as? NSNumber)?.doubleValue }
func dictionary(_ d: [String: Any], _ key: String) -> [String: Any] { d[key] as? [String: Any] ?? [:] }
func bytes(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "—" }
    let units = ["Б", "КБ", "МБ", "ГБ", "ТБ"]
    var n = max(0, value), i = 0
    while n >= 1024 && i < 4 { n /= 1024; i += 1 }
    return String(format: i == 0 ? "%.0f %@" : "%.1f %@", n, units[i])
}
func percent(_ n: Double?) -> String { n.map { String(format: "%.1f %%", $0) } ?? "—" }
func integer(_ n: Double?) -> String { n.map { Int($0).formatted(.number.locale(Locale(identifier: "ru_RU"))) } ?? "—" }
func minutes(_ n: Double?) -> String {
    guard let n, n > 0, n < 100000 else { return "Уточняется" }
    return String(format: "%d ч %02d мин", Int(n)/60, Int(n)%60)
}

struct Point: Codable {
    var time: Double
    var values: [String: Double]
    var charging: Bool = false
}

// Missing counters remain missing; the first sample and counter resets never create artificial spikes.
func difference(_ current: Double?, _ old: Double?, seconds: Double) -> Double? {
    guard let current, let old, seconds > 0, current >= old else { return nil }
    return (current-old)/seconds
}

final class Monitor: ObservableObject {
    @Published var selectedTab: Tab = .overview
    private(set) var statusTab: Tab = .memory
    @Published var current: [String: Double] = [:]
    @Published var history: [Point] = []
    @Published var batteryHistory: [Point] = []
    @Published var powerText = "Нет данных об аккумуляторе"
    @Published var interfaces = ""
    @Published var batteryTime = "—"
    @Published var batteryTimeTitle = "Оставшееся время"
    @Published var updated: Date?
    @Published var charging = false
    var onUpdate: (() -> Void)?
    private var previous: [String: Any] = [:]
    private let queue = DispatchQueue(label: "ai.anodhas.MemoryBar.sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let historyURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ai.anodhas.MemoryBar/battery-history.json")

    init() {
        selectedTab = Tab(rawValue: UserDefaults.standard.string(forKey: "selectedTab") ?? "") ?? .overview
        statusTab = Tab(rawValue: UserDefaults.standard.string(forKey: "statusTab") ?? "") ?? .memory
        if statusTab == .overview { statusTab = .memory }
        if let data = try? Data(contentsOf: historyURL), let points = try? JSONDecoder().decode([Point].self, from: data) {
            batteryHistory = points.filter { $0.time > Date().timeIntervalSince1970 - 43200 }
        }
    }
    func selectTab(_ tab: Tab) {
        selectedTab = tab
        if tab != .overview { statusTab = tab }
        UserDefaults.standard.set(selectedTab.rawValue, forKey: "selectedTab")
        UserDefaults.standard.set(statusTab.rawValue, forKey: "statusTab")
        onUpdate?()
    }
    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 2, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in self?.sample() }
        self.timer = timer
        timer.resume()
    }
    private func sample() {
        let raw = readMetrics()
        let now = number(raw, "time") ?? Date().timeIntervalSince1970
        let elapsed = now - (number(previous, "time") ?? now)
        var v: [String: Double] = [:]
        let mem = dictionary(raw, "memory")
        for key in ["used", "wired", "compressed", "cached"] { v[key] = number(mem, key) }
        v["totalMemory"] = number(raw, "totalMemory")
        v["swap"] = number(raw, "swap")
        if let used = v["used"], let total = v["totalMemory"], total > 0 { v["ram"] = min(100, max(0, used/total*100)) }
        v["processes"] = number(raw, "processes")
        v["load"] = number(raw, "load")
        if let cpu = raw["cpu"] as? [Double], let old = previous["cpu"] as? [Double], cpu.count == 4, old.count == 4 {
            let delta = zip(cpu, old).map { $0 >= $1 ? $0-$1 : $0 + 4294967296 - $1 }
            let total = delta.reduce(0, +)
            if total > 0 {
                v["user"] = (delta[0]+delta[3])/total*100
                v["system"] = delta[1]/total*100
                v["idle"] = delta[2]/total*100
                v["cpu"] = 100 - (v["idle"] ?? 100)
            }
        }
        for (section, keys) in [("network", ["rx", "tx", "inPackets", "outPackets"]), ("disk", ["read", "write", "reads", "writes"])] {
            let sub = dictionary(raw, section), old = dictionary(previous, section)
            let sameNetwork = section != "network" || (sub["interfaces"] as? [String]) == (old["interfaces"] as? [String])
            for key in keys {
                v[key] = number(sub, key)
                if sameNetwork { v[key+"Rate"] = difference(number(sub, key), number(old, key), seconds: elapsed) }
            }
        }
        let netNames = (dictionary(raw, "network")["interfaces"] as? [String] ?? []).joined(separator: ", ")
        let battery = dictionary(raw, "battery")
        v["battery"] = number(battery, "percent")
        v["watts"] = number(battery, "watts")
        v["cycles"] = number(battery, "cycles")
        let isCharging = battery["charging"] as? Bool ?? false
        let ac = battery["power"] as? String == "AC Power"
        let power = battery.isEmpty ? "Аккумулятор не найден" : isCharging ? "Заряжается от сети" : ac ? "Подключён к сети" : "Питание от аккумулятора"
        let timeTitle = ac ? "До полной зарядки" : "До разрядки"
        let timeText = ac && !isCharging ? "Не заряжается" : minutes(number(battery, ac ? "toFull" : "toEmpty"))
        previous = raw
        let point = Point(time: now, values: v, charging: isCharging)
        DispatchQueue.main.async {
            self.current = v
            self.history.append(point)
            self.history = self.history.filter { $0.time >= now-120 }
            self.powerText = power; self.charging = isCharging
            self.interfaces = netNames
            self.batteryTimeTitle = timeTitle; self.batteryTime = timeText
            self.updated = Date(timeIntervalSince1970: now)
            if v["battery"] != nil && now - (self.batteryHistory.last?.time ?? 0) >= 60 {
                self.batteryHistory.append(point)
                self.batteryHistory = self.batteryHistory.filter { $0.time >= now-43200 }
                let points = self.batteryHistory.map { Point(time: $0.time, values: $0.values.filter { ["battery", "watts"].contains($0.key) }, charging: $0.charging) }
                let url = self.historyURL
                self.queue.async {
                    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let data = try? JSONEncoder().encode(points) { try? data.write(to: url, options: .atomic) }
                }
            }
            self.onUpdate?()
        }
    }
}

enum Tab: String, CaseIterable {
    case overview = "Обзор", memory = "RAM", cpu = "ЦП", network = "Сеть", disk = "Диск", battery = "Батарея"
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .memory: return "memorychip"
        case .cpu: return "cpu"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .battery: return "battery.75percent"
        }
    }
}
let cyan = Color(red: 0.18, green: 0.79, blue: 0.91)
let coral = Color(red: 1, green: 0.36, blue: 0.40)
let panelWidth: CGFloat = 560
let panelHeight: CGFloat = 600

struct GlassSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16)
        if reduceTransparency {
            content.background(Color(nsColor: .controlBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            content.background {
                shape.fill(Color.white.opacity(0.025)).glassEffect(.clear, in: shape)
                    .allowsHitTesting(false)
            }.overlay(shape.strokeBorder(.white.opacity(0.13)).allowsHitTesting(false))
        } else {
            content.background(.ultraThinMaterial, in: shape)
        }
    }
}

struct TileButtonStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : hovered ? 0.055 : 0), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.white.opacity(hovered ? 0.18 : 0)).allowsHitTesting(false))
            .onHover { hovered = $0 }
    }
}

struct Graph: View {
    var points: [Point]
    var first: String
    var second: String? = nil
    var ceiling: Double? = nil
    var duration: Double = 120
    var shadeCharging = false
    var body: some View {
        Canvas { context, size in
            for i in 0...3 {
                let y = CGFloat(i)/3*size.height
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(p, with: .color(.primary.opacity(0.07)), lineWidth: 1)
            }
            let end = points.last?.time ?? Date().timeIntervalSince1970
            if shadeCharging {
                for (i, point) in points.enumerated() where point.charging && i+1 < points.count {
                    let next = points[i+1]
                    guard next.time-point.time < 125 else { continue }
                    let x = max(0, (point.time-end+duration)/duration)*size.width
                    let right = min(size.width, (next.time-end+duration)/duration*size.width)
                    context.fill(Path(CGRect(x: x, y: 0, width: max(0, right-x), height: size.height)), with: .color(.green.opacity(0.15)))
                }
            }
            let maxValue = max(ceiling ?? points.flatMap { p in [p.values[first], second.flatMap { p.values[$0] }].compactMap { $0 } }.max() ?? 1, 0.001)
            for (key, color) in [(first, cyan), (second ?? "", coral)] where !key.isEmpty {
                var path = Path(), started = false
                var lastTime: Double?
                for p in points {
                    guard let value = p.values[key] else { started = false; continue }
                    if let lastTime, p.time-lastTime > (duration > 120 ? 125 : 6) { started = false }
                    let x = max(0, min(1, (p.time-end+duration)/duration))*size.width
                    let y = size.height - max(0, min(1, value/maxValue))*size.height
                    if started { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); started = true }
                    lastTime = p.time
                }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(height: 70)
        .accessibilityLabel("График изменения показателей")
    }
}

struct Line: View {
    var title: String
    var value: String
    var tint: Color = .primary
    var body: some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit().foregroundStyle(tint) }
            .font(.system(size: 12)).padding(.vertical, 3)
    }
}
struct Card<Content: View>: View {
    var title: String
    var icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassSurface())
    }
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    var tab: Tab { monitor.selectedTab }
    var v: [String: Double] { monitor.current }
    func rate(_ key: String) -> String { v[key].map { bytes($0)+"/с" } ?? "Ожидание замера" }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 21)).foregroundStyle(cyan)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Мониторинг Mac").font(.system(size: 18, weight: .semibold))
                    Text("Состояние компьютера сейчас").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    Button("Открыть Мониторинг системы", action: openActivityMonitor)
                    Button("Настройки автозапуска…") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!) }
                    Divider()
                    Button("Завершить Мониторинг RAM") { NSApp.terminate(nil) }
                } label: { Image(systemName: "ellipsis.circle").font(.system(size: 20)).foregroundStyle(.secondary) }
                .menuStyle(.borderlessButton).frame(width: 28)
            }.padding(.horizontal, 18).padding(.vertical, 14)
            HStack(spacing: 4) {
                ForEach(Tab.allCases, id: \.self) { item in
                    Button { monitor.selectTab(item) } label: {
                        VStack(spacing: 5) { Image(systemName: item.symbol).font(.system(size: 16)); Text(item.rawValue).font(.system(size: 11, weight: .medium)) }
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .foregroundStyle(tab == item ? cyan : .secondary)
                            .background(tab == item ? cyan.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 11))
                            .contentShape(Rectangle())
                    }.buttonStyle(TileButtonStyle())
                        .accessibilityAddTraits(tab == item ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.12)).allowsHitTesting(false))
            .padding(.horizontal, 12).padding(.bottom, 12)
            Divider()
            VStack(spacing: 12) {
                    if tab == .overview { overview }
                    else if tab == .memory { memory }
                    else if tab == .cpu { cpu }
                    else if tab == .network { network }
                    else if tab == .disk { disk }
                    else { battery }
                Spacer(minLength: 0)
            }.padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            HStack {
                Circle().fill(monitor.updated == nil ? .gray : .green).frame(width: 5, height: 5)
                Text(monitor.updated == nil ? "Получаем данные…" : "Обновление каждые 2 секунды")
                Spacer()
                Button("Мониторинг системы", action: openActivityMonitor).buttonStyle(.plain).foregroundStyle(cyan)
            }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 20).padding(.vertical, 12)
        }.frame(width: panelWidth, height: panelHeight)
            .background(Color.black.opacity(0.24))
            .clipShape(RoundedRectangle(cornerRadius: 24))
    }
    func tile(_ item: Tab, _ big: String, _ detail: String) -> some View {
        Button { monitor.selectTab(item) } label: {
            Card(title: item == .memory ? "Оперативная память" : item.rawValue, icon: item.symbol) {
                Text(big).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(.primary)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(TileButtonStyle())
    }
    var overview: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                tile(.memory, percent(v["ram"]), bytes(v["used"])+" из "+bytes(v["totalMemory"]))
                tile(.cpu, percent(v["cpu"]), "Свободно: "+percent(v["idle"]))
                tile(.network, rate("rxRate"), "↑ "+rate("txRate"))
                tile(.disk, rate("writeRate"), "Чтение: "+rate("readRate"))
            }
            Card(title: "Загрузка процессора · последние 2 минуты", icon: "chart.xyaxis.line") {
                Graph(points: monitor.history, first: "user", second: "system", ceiling: 100)
                legend("Пользователь", "Система")
            }
            HStack { Image(systemName: Tab.battery.symbol).foregroundStyle(cyan); Text(percent(v["battery"])).monospacedDigit(); Spacer(); Text(monitor.powerText).foregroundStyle(.secondary) }.font(.system(size: 12)).padding(.horizontal, 5)
        }
    }
    func legend(_ first: String, _ second: String) -> some View {
        HStack(spacing: 18) {
            Label(first, systemImage: "circle.fill").foregroundStyle(cyan)
            Label(second, systemImage: "circle.fill").foregroundStyle(coral)
            Spacer()
        }.font(.system(size: 10))
    }
    var memory: some View {
        VStack(spacing: 14) {
            Card(title: "Занятая оперативная память", icon: "memorychip") {
                HStack(alignment: .firstTextBaseline) { Text(percent(v["ram"])).font(.system(size: 36, weight: .semibold, design: .rounded)); Spacer(); Text(bytes(v["used"])+" / "+bytes(v["totalMemory"])).foregroundStyle(.secondary) }
                Graph(points: monitor.history, first: "ram", ceiling: 100)
                Text("Последние 2 минуты · шкала 0–100 %").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Card(title: "Использование памяти", icon: "square.stack.3d.up") {
                VStack(spacing: 0) {
                    Line(title: "Используется", value: bytes(v["used"]))
                    Line(title: "Проводная память", value: bytes(v["wired"]))
                    Line(title: "Сжатая память", value: bytes(v["compressed"]))
                    Line(title: "Кэш файлов", value: bytes(v["cached"]))
                    Divider().padding(.vertical, 4)
                    Line(title: "Использовано swap", value: bytes(v["swap"]))
                }
            }
        }
    }
    var cpu: some View {
        VStack(spacing: 14) {
            Card(title: "Загрузка процессора", icon: "cpu") {
                HStack(spacing: 24) {
                    Text(percent(v["cpu"])).font(.system(size: 32, weight: .semibold, design: .rounded))
                    Spacer()
                    VStack(spacing: 0) {
                        Line(title: "Пользователь", value: percent(v["user"]), tint: cyan)
                        Line(title: "Система", value: percent(v["system"]), tint: coral)
                        Line(title: "Свободно", value: percent(v["idle"]))
                    }.frame(width: 240)
                }
                Graph(points: monitor.history, first: "user", second: "system", ceiling: 100)
                legend("Пользователь", "Система")
            }
            Card(title: "Система", icon: "gearshape.2") {
                Line(title: "Процессы", value: integer(v["processes"]))
                Line(title: "Логические ядра", value: "\(ProcessInfo.processInfo.processorCount)")
                Line(title: "Средняя нагрузка за минуту", value: v["load"].map { String(format: "%.2f", $0) } ?? "—")
            }
        }
    }
    var network: some View {
        VStack(spacing: 14) {
            Card(title: "Скорость сети", icon: "network") {
                HStack { Text("↓ "+rate("rxRate")).foregroundStyle(cyan); Spacer(); Text("↑ "+rate("txRate")).foregroundStyle(coral) }.font(.system(size: 21, weight: .semibold)).monospacedDigit()
                Graph(points: monitor.history, first: "rxRate", second: "txRate")
                legend("Получение", "Отправка")
            }
            Card(title: "Трафик и пакеты", icon: "arrow.up.arrow.down") {
                HStack(spacing: 16) {
                    VStack(spacing: 0) {
                        Line(title: "Получено", value: bytes(v["rx"]))
                        Line(title: "Пакеты ↓", value: integer(v["inPackets"]))
                        Line(title: "Пакетов/с ↓", value: integer(v["inPacketsRate"]), tint: cyan)
                    }
                    Divider()
                    VStack(spacing: 0) {
                        Line(title: "Отправлено", value: bytes(v["tx"]))
                        Line(title: "Пакеты ↑", value: integer(v["outPackets"]))
                        Line(title: "Пакетов/с ↑", value: integer(v["outPacketsRate"]), tint: coral)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("Физические интерфейсы: \(monitor.interfaces.isEmpty ? "не найдены" : monitor.interfaces). Суммы — с запуска интерфейсов; VPN-туннели повторно не считаются.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var disk: some View {
        VStack(spacing: 14) {
            Card(title: "Ввод / вывод диска", icon: "internaldrive") {
                HStack { Text("↓ "+rate("readRate")).foregroundStyle(cyan); Spacer(); Text("↑ "+rate("writeRate")).foregroundStyle(coral) }.font(.system(size: 21, weight: .semibold)).monospacedDigit()
                Graph(points: monitor.history, first: "readRate", second: "writeRate")
                legend("Чтение", "Запись")
            }
            Card(title: "Обращения к накопителям", icon: "externaldrive") {
                HStack(spacing: 16) {
                    VStack(spacing: 0) {
                        Line(title: "Прочитано", value: bytes(v["read"]))
                        Line(title: "Чтений", value: integer(v["reads"]))
                        Line(title: "Чтений/с", value: integer(v["readsRate"]), tint: cyan)
                    }
                    Divider()
                    VStack(spacing: 0) {
                        Line(title: "Записано", value: bytes(v["write"]))
                        Line(title: "Записей", value: integer(v["writes"]))
                        Line(title: "Записей/с", value: integer(v["writesRate"]), tint: coral)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            Text("Суммарные счётчики накопителей, доступных macOS, с момента подключения. График — последние 2 минуты.").font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var battery: some View {
        VStack(spacing: 14) {
            Card(title: "Аккумулятор", icon: "battery.75percent") {
                HStack { Text(percent(v["battery"])).font(.system(size: 36, weight: .semibold, design: .rounded)); Spacer(); Text(monitor.powerText).foregroundStyle(.secondary) }
                Line(title: monitor.batteryTimeTitle, value: monitor.batteryTime)
                Line(title: monitor.charging ? "Мощность зарядки батареи" : "Мощность на батарее", value: v["watts"].map { String(format: "%.1f Вт", $0) } ?? "Недоступно")
                Line(title: "Циклы зарядки", value: integer(v["cycles"]))
            }
            Card(title: "История аккумулятора", icon: "chart.xyaxis.line") {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Заряд · до 12 часов").font(.system(size: 12, weight: .medium))
                        Graph(points: monitor.batteryHistory, first: "battery", ceiling: 100, duration: 43200, shadeCharging: true)
                        Text(monitor.batteryHistory.count < 2 ? "Один замер в минуту. История накапливается." : "История сохраняется между запусками.").font(.system(size: 10)).foregroundStyle(.secondary)
                        Label("Зелёный фон — зарядка", systemImage: "bolt.fill").font(.system(size: 10)).foregroundStyle(.green)
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Мощность · 2 минуты").font(.system(size: 12, weight: .medium))
                        Graph(points: monitor.history, first: "watts")
                        Text("Мощность на батарее в ваттах. При питании от сети это не полное потребление Mac.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .topLeading)
                }.fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

func openActivityMonitor() { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }

func statusPresentation(_ mode: Tab, _ v: [String: Double], charging: Bool) -> (symbol: String, title: String, help: String) {
    func rounded(_ key: String) -> String { v[key].map { "\(Int($0.rounded()))%" } ?? "—" }
    func rate(_ key: String) -> String { v[key].map { bytes($0)+"/с" } ?? "—" }
    switch mode {
    case .cpu: return ("cpu", " " + rounded("cpu"), "ЦП: " + percent(v["cpu"]))
    case .network: return ("network", " ↓ " + rate("rxRate"), "Сеть · получение: " + rate("rxRate") + "; отправка: " + rate("txRate"))
    case .disk: return ("internaldrive", " ↑ " + rate("writeRate"), "Диск · чтение: " + rate("readRate") + "; запись: " + rate("writeRate"))
    case .battery: return (charging ? "battery.100percent.bolt" : "battery.75percent", " " + rounded("battery"), "Батарея: " + rounded("battery") + (charging ? " · заряжается" : ""))
    case .memory, .overview: return ("memorychip", " " + rounded("ram"), "Память: " + bytes(v["used"]) + " из " + bytes(v["totalMemory"]))
    }
}

final class MonitorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    let panel = MonitorPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var statusItem: NSStatusItem!
    var outsideMonitor: Any?
    var insideMonitor: Any?
    var screenObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: 76)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "memorychip", accessibilityDescription: "Мониторинг RAM")
            button.imagePosition = .imageLeading
            button.title = " …"
            button.toolTip = "Мониторинг Mac — нажмите, чтобы открыть показатели"
            button.target = self; button.action = #selector(toggle)
            button.setButtonType(.momentaryChange)
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: Dashboard(monitor: monitor).preferredColorScheme(.dark))
        hosting.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hosting.autoresizingMask = [.width, .height]
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: hosting.frame)
            glass.style = .clear
            glass.cornerRadius = 24
            glass.tintColor = NSColor(srgbRed: 0.06, green: 0.075, blue: 0.10, alpha: 0.30)
            glass.contentView = hosting
            panel.contentView = glass
        } else {
            let glass = NSVisualEffectView(frame: hosting.frame)
            glass.material = .hudWindow
            glass.blendingMode = .behindWindow
            glass.state = .active
            glass.wantsLayer = true
            glass.layer?.cornerRadius = 24
            glass.layer?.masksToBounds = true
            glass.addSubview(hosting)
            panel.contentView = glass
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.panel.orderOut(nil) }
        insideMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if self.panel.isVisible && event.type == .keyDown && event.keyCode == 53 {
                self.panel.orderOut(nil); return nil
            }
            if event.type != .keyDown && event.window !== self.panel && event.window !== self.statusItem.button?.window { self.panel.orderOut(nil) }
            return event
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            if self?.panel.isVisible == true { self?.positionPanel() }
        }
        monitor.onUpdate = { [weak self] in self?.updateStatus() }
        updateStatus()
        monitor.start()
        show()
    }
    @objc func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { show() }
    }
    func updateStatus() {
        guard let button = statusItem.button else { return }
        let value = statusPresentation(monitor.statusTab, monitor.current, charging: monitor.charging)
        button.image = NSImage(systemSymbolName: value.symbol, accessibilityDescription: monitor.statusTab.rawValue)
        button.title = value.title
        button.toolTip = value.help + "\nНажмите, чтобы выбрать другой показатель"
        statusItem.length = max(76, ceil(button.cell?.cellSize.width ?? 76) + 16)
    }
    func positionPanel() {
        guard let button = statusItem.button, let window = button.window else { return }
        let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = window.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = min(max(anchor.midX-panelWidth/2, visible.minX+8), visible.maxX-panelWidth-8)
        let y = max(visible.minY+8, anchor.minY-panelHeight-8)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
    func show() {
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
        if let insideMonitor { NSEvent.removeMonitor(insideMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
    func application(_ application: NSApplication, open urls: [URL]) { if urls.contains(where: { $0.scheme == "memorybar" }) { show() } }
}

if CommandLine.arguments.contains("--probe") {
    let a = readMetrics()
    Thread.sleep(forTimeInterval: 2)
    let b = readMetrics()
    let output = ["first": a, "second": b]
    if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) { print(String(decoding: data, as: UTF8.self)) }
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
    precondition(difference(110, 100, seconds: 2) == 5)
    precondition(difference(2, 100, seconds: 2) == nil)
    precondition(difference(110, nil, seconds: 2) == nil)
    precondition(difference(110, 100, seconds: 0) == nil)
    precondition(bytes(nil) == "—")
    precondition(minutes(-1) == "Уточняется")
    print("PASS: rates, missing data, counter reset, time estimates")
    exit(0)
}
let app = NSApplication.shared
if !NSRunningApplication.runningApplications(withBundleIdentifier: "ai.anodhas.MemoryBar").filter({ $0.processIdentifier != getpid() }).isEmpty {
    if let other = NSRunningApplication.runningApplications(withBundleIdentifier: "ai.anodhas.MemoryBar").first(where: { $0.processIdentifier != getpid() }) { other.activate(options: [])
        NSWorkspace.shared.open(URL(string: "memorybar://show")!) }
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
