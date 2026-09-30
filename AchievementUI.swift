import Cocoa
import SwiftUI

// Shared by the live page, unlock toast and exported card: vector badges stay sharp at every size.
extension Achievement {
    var symbol: String {
        switch id {
        case "d1": return "leaf.fill"
        case "d3": return "wrench.adjustable.fill"
        case "d7": return "calendar"
        case "d10": return "medal.fill"
        case "d30": return "building.2.fill"
        case "d100": return "star.circle.fill"
        case "d365": return "crown.fill"
        case "a5": return "drop.fill"
        case "a30": return "bolt.heart.fill"
        case "a50": return "shield.lefthalf.filled"
        case "a70": return "banknote.fill"
        case "a90": return "sun.max.fill"
        case "shapes5": return "square.grid.3x3.fill"
        case "line": return "ruler.fill"
        case "multi": return "display.2"
        case "block100": return "shield.checkered"
        case "block500": return "shield.lefthalf.filled"
        case "block1k": return "bolt.shield.fill"
        case "block2k": return "lock.shield.fill"
        case "block5k": return "crown.fill"
        case "block10k": return "hand.raised.fill"
        default: return "macwindow.on.rectangle"
        }
    }
    var tint: Color {
        if id.hasPrefix("d") { return id == "d365" ? .orange : .cyan }
        if id.hasPrefix("a") { return .purple }
        if id.hasPrefix("block") { return .orange }
        return .blue
    }
}

enum AchievementTrack: String, CaseIterable, Identifiable {
    case time, damage, protection
    var id: String { rawValue }
    var title: String {
        switch self {
        case .time: return L("坚持时间", "Time in Use")
        case .damage: return L("坏屏生存", "Screen Survivor")
        case .protection: return L("鼠标防护", "Cursor Protection")
        }
    }
    var ids: [String] {
        switch self {
        case .time: return ["d1", "d3", "d7", "d10", "d30", "d100", "d365"]
        case .damage: return ["a5", "a30", "a50", "a70", "a90"]
        case .protection: return ["block100", "block500", "block1k", "block2k", "block5k", "block10k"]
        }
    }
    var thresholds: [Double] {
        switch self {
        case .time: return [1, 3, 7, 10, 30, 100, 365]
        case .damage: return [5, 30, 50, 70, 90]
        case .protection: return [100, 500, 1_000, 2_000, 5_000, 10_000]
        }
    }
    var achievements: [Achievement] { ids.compactMap { id in Achievement.all.first { $0.id == id } } }
    func value(_ r: Report) -> Double {
        switch self {
        case .time: return Double(r.days)
        case .damage: return (r.worst?.damage ?? 0) * 100
        case .protection: return Double(r.blocks)
        }
    }
    func label(_ index: Int) -> String {
        let n = Int(thresholds[index]).formatted()
        switch self {
        case .time: return L("\(n)天", "\(n)d")
        case .damage: return "\(n)%"
        case .protection: return L("\(n)次", n)
        }
    }
    func earned(_ r: Report) -> [Achievement] { achievements.filter { r.unlocked[$0.id] != nil } }
    func next(_ r: Report) -> Achievement? { achievements.first { r.unlocked[$0.id] == nil } }
    // Nodes represent levels, not a linear numeric scale. Interpolate only within a level interval.
    // Previously earned levels never regress when a screen is disconnected or its zones are edited.
    func progress(_ r: Report) -> Double {
        let saved = ids.lastIndex { r.unlocked[$0] != nil } ?? -1
        let v = max(value(r), saved >= 0 ? thresholds[saved] : 0)
        if v < thresholds[0] { return 0 }
        for i in 1..<thresholds.count where v < thresholds[i] {
            return (Double(i - 1) + (v - thresholds[i - 1]) / (thresholds[i] - thresholds[i - 1])) / Double(thresholds.count - 1)
        }
        return 1
    }
    func status(_ r: Report) -> String {
        guard let next = next(r), let i = ids.firstIndex(of: next.id) else { return L("这条主线已全部解锁", "Every milestone unlocked") }
        if self == .time { return L("再使用 \(max(0, Int(thresholds[i]) - r.days)) 天，解锁「\(next.title)」", "\(max(0, Int(thresholds[i]) - r.days)) more days to unlock \(next.title)") }
        return L("下一枚：\(next.title) · \(next.desc)", "Next: \(next.title) · \(next.desc)")
    }
    static var independent: [Achievement] {
        let grouped = Set(allCases.flatMap(\.ids))
        return Achievement.all.filter { !grouped.contains($0.id) }
    }
    static func showcase(_ r: Report) -> [Achievement] {
        allCases.compactMap { $0.earned(r).last } + independent.filter { r.unlocked[$0.id] != nil }
    }
}

struct MilestoneProgress {
    let track: AchievementTrack
    let index: Int
    let report: Report
    var target: Double { track.thresholds[index] }
    var current: Double { track.value(report) }
    var fraction: Double { min(1, max(0, current / target)) }
    var remaining: Double { max(0, target - current) }
    var earned: Bool { report.unlocked[track.ids[index]] != nil }
    func formatted(_ value: Double) -> String {
        if track == .damage { return String(format: "%.1f%%", value) }
        return Int(value).formatted() + (track == .time ? L(" 天", " days") : L(" 次", " times"))
    }
    var summary: String { L("当前 ", "Current ") + formatted(current) + " / " + formatted(target) }
    static func of(_ a: Achievement, report: Report) -> MilestoneProgress? {
        for track in AchievementTrack.allCases {
            if let index = track.ids.firstIndex(of: a.id) { return MilestoneProgress(track: track, index: index, report: report) }
        }
        return nil
    }
}

struct MilestoneProgressView: View {
    let progress: MilestoneProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(progress.summary).font(.callout.monospacedDigit())
                Spacer()
                Text(String(format: "%.1f%%", progress.fraction * 100)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction).tint(progress.track.achievements[0].tint)
            Text(progress.earned ? L("已解锁 · 永久保留", "Unlocked · yours to keep") : L("还差 ", "Remaining: ") + progress.formatted(progress.remaining))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MilestoneHoverCard: View {
    let a: Achievement
    let progress: MilestoneProgress
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Medal3D(a: a, unlocked: progress.earned).frame(width: 92, height: 100)
                VStack(alignment: .leading, spacing: 5) {
                    Text(a.title).font(.headline)
                    Text(a.desc).font(.caption).foregroundStyle(.secondary)
                }
            }
            MilestoneProgressView(progress: progress)
            Text(L("点击节点，查看 3D 徽章", "Click the milestone to inspect its 3D badge")).font(.caption2).foregroundStyle(.tertiary)
        }.padding(18).frame(width: 320)
    }
}

struct MedalHexagon: SwiftUI.Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            let inset = rect.width * 0.07
            let points = [CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX - inset, y: rect.height * 0.25 + rect.minY), CGPoint(x: rect.maxX - inset, y: rect.height * 0.75 + rect.minY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX + inset, y: rect.height * 0.75 + rect.minY), CGPoint(x: rect.minX + inset, y: rect.height * 0.25 + rect.minY)]
            p.addLines(points); p.closeSubpath()
        }
    }
}

struct AchievementMedal: View {
    let a: Achievement
    var unlocked = true
    var size: CGFloat = 64
    var body: some View {
        let color = unlocked ? a.tint : Color.gray
        ZStack {
            MedalHexagon().fill(LinearGradient(colors: [Color.white.opacity(unlocked ? 0.95 : 0.3), color, color.opacity(0.45), Color.white.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
            MedalHexagon().fill(LinearGradient(colors: [color.opacity(0.85), color.opacity(0.23), color.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing)).padding(size * 0.065)
            MedalHexagon().stroke(Color.white.opacity(unlocked ? 0.45 : 0.13), lineWidth: 1).padding(size * 0.10)
            Image(systemName: a.symbol)
                .font(.system(size: size * 0.35, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [.white, unlocked ? color.opacity(0.8) : .gray], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.4), radius: 1, y: 2)
        }
        .frame(width: size, height: size * 1.08)
        .shadow(color: color.opacity(unlocked ? 0.38 : 0), radius: size * 0.12, y: 3)
        .opacity(unlocked ? 1 : 0.5)
        .accessibilityHidden(true)
    }
}

struct MilestoneBar: View {
    let track: AchievementTrack
    let report: Report
    var select: ((Achievement) -> Void)? = nil
    var body: some View {
        GeometryReader { geometry in
            let cell = geometry.size.width / CGFloat(track.ids.count)
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.secondary.opacity(0.2)).frame(width: geometry.size.width - cell, height: 4).offset(x: cell / 2, y: 12)
                Capsule().fill(track.achievements[0].tint).frame(width: (geometry.size.width - cell) * track.progress(report), height: 4).offset(x: cell / 2, y: 12)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(track.achievements.enumerated()), id: \.element.id) { i, a in
                        MilestoneNode(a: a, on: report.unlocked[a.id] != nil,
                                      next: track.next(report)?.id == a.id, label: track.label(i), width: cell,
                                      progress: select == nil ? nil : MilestoneProgress(track: track, index: i, report: report)) { select?(a) }
                    }
                }
            }
        }.frame(height: 52)
    }
}

private struct MilestoneNode: View {
    let a: Achievement
    let on: Bool, next: Bool
    let label: String
    let width: CGFloat
    let progress: MilestoneProgress?
    let action: () -> Void
    @State private var hovering = false
    private var symbol: String { on ? "checkmark" : (next ? "circle.fill" : "lock.fill") }
    private var foreground: Color { on ? .white : (next ? a.tint : .secondary) }
    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                ZStack {
                    Circle().fill(on ? a.tint : Color(nsColor: .windowBackgroundColor))
                    Circle().stroke(on || next ? a.tint : Color.secondary.opacity(0.35), lineWidth: next ? 2 : 1)
                    Image(systemName: symbol).font(.system(size: next && !on ? 6 : 10, weight: .bold)).foregroundStyle(foreground)
                }.frame(width: 27, height: 27)
                Text(label).font(.system(size: 10, weight: on || next ? .semibold : .regular)).foregroundStyle(on || next ? Color.primary : .secondary)
            }.frame(width: width)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 && progress != nil }
        .popover(isPresented: $hovering, arrowEdge: .bottom) {
            if let progress { MilestoneHoverCard(a: a, progress: progress) }
        }
        .accessibilityValue(progress?.summary ?? "")
        .accessibilityLabel(a.title + " · " + a.desc + (on ? L("，已解锁", ", unlocked") : L("，未解锁", ", locked")))
    }
}

struct TrackCard: View {
    let track: AchievementTrack
    let report: Report
    let select: (Achievement) -> Void
    @State private var hovering = false
    var body: some View {
        let earned = track.earned(report)
        let badge = earned.last ?? track.achievements[0]
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 14) {
                Button { select(badge) } label: { InteractiveMedal(a: badge, unlocked: !earned.isEmpty, size: 52) }.buttonStyle(.plain).help(badge.title)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(track.title).font(.headline)
                        Text("\(earned.count)/\(track.ids.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 2).background(Color.primary.opacity(0.05), in: Capsule())
                    }
                    Text(earned.last?.title ?? L("旅程即将开始", "Your journey starts here")).font(.callout.weight(.medium))
                    Text(track.status(report)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    let nextBadge = track.next(report) ?? badge
                    if let progress = MilestoneProgress.of(nextBadge, report: report) {
                        Text(hovering ? progress.summary + (progress.earned ? "" : L(" · 还差 ", " · Remaining: ") + progress.formatted(progress.remaining)) : L("悬停节点查看进度 · 点击查看 3D 徽章", "Hover a milestone for progress · Click for its 3D badge"))
                            .font(.caption2).foregroundStyle(hovering ? badge.tint : .secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            MilestoneBar(track: track, report: report, select: select)
        }
        .padding(16)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.09)))
        .onHover { hovering = $0 }
    }
}

struct BadgeView: View {
    let a: Achievement, date: Double?
    var body: some View {
        VStack(spacing: 9) {
            InteractiveMedal(a: a, unlocked: date != nil, size: 56)
            Text(a.title).font(.callout.bold()).multilineTextAlignment(.center)
            Label(date != nil ? L("已解锁", "Unlocked") : L("未解锁", "Locked"), systemImage: date != nil ? "checkmark.circle.fill" : "lock.fill").font(.caption2).foregroundStyle(date != nil ? a.tint : .secondary)
            Text(a.desc).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(minHeight: 28)
        }
        .frame(maxWidth: .infinity).padding(13)
        .background(date != nil ? a.tint.opacity(0.09) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(date != nil ? a.tint.opacity(0.45) : Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
    }
}

struct AchievementDetail: View {
    let a: Achievement, date: Double?
    let report: Report
    @State private var rotating = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 15) {
            Medal3D(a: a, unlocked: date != nil, rotating: rotating)
                .frame(width: 230, height: 230)
                .background(RadialGradient(colors: [a.tint.opacity(0.2), .clear], center: .center, startRadius: 15, endRadius: 115))
            if !reduceMotion {
                Button(rotating ? L("暂停旋转", "Pause Rotation") : L("继续旋转", "Resume Rotation")) { rotating.toggle() }.font(.caption)
            }
            Text(a.title).font(.title2.bold())
            Text(a.desc).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let date {
                Label(L("已解锁", "Unlocked"), systemImage: "checkmark.seal.fill").foregroundStyle(a.tint)
                Text(unlockTime(Date(timeIntervalSince1970: date))).font(.caption).foregroundStyle(.secondary)
            } else { Label(L("尚未解锁", "Not unlocked yet"), systemImage: "lock.fill").foregroundStyle(.secondary) }
            if let progress = MilestoneProgress.of(a, report: report) { MilestoneProgressView(progress: progress).padding(.vertical, 8) }
            Button(L("完成", "Done")) { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(32).frame(width: 330)
    }
}

private enum CardArtwork {
    static let backdrop: NSImage? = image("ShareCardBackdrop", ext: "png")
    static let icon: NSImage? = image("AppIcon", ext: "icns")
    private static func image(_ name: String, ext: String) -> NSImage? {
        // App bundles use their packaged resources; the render harness uses an explicit resource folder.
        let testFolder = ProcessInfo.processInfo.environment["DEADZONE_RENDER_RESOURCES"]
        let url = Bundle.main.url(forResource: name, withExtension: ext)
            ?? testFolder.map { URL(fileURLWithPath: $0).appendingPathComponent(name + "." + ext) }
        return url.flatMap { NSImage(contentsOf: $0) }
    }
}

struct ShareCard: View {
    let r: Report
    private var badges: [Achievement] { AchievementTrack.showcase(r) }
    private var earnedCount: Int { Achievement.all.filter { r.unlocked[$0.id] != nil }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if let icon = CardArtwork.icon { Image(nsImage: icon).resizable().frame(width: 46, height: 46) }
                VStack(alignment: .leading, spacing: 3) {
                    Text("DeadZone").font(.system(size: 21, weight: .bold))
                    Text(L("坏屏战绩", "SCREEN SURVIVOR")).font(.system(size: 12, weight: .medium)).tracking(1.3).foregroundStyle(Color(red: 0.66, green: 0.73, blue: 0.96))
                }
                Spacer()
                Image(systemName: "sparkle").font(.system(size: 19)).foregroundStyle(.white.opacity(0.4))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(pct(r.worst?.damage ?? 0)).font(.system(size: 78, weight: .heavy, design: .rounded)).tracking(-3)
                    .shadow(color: .blue.opacity(0.28), radius: 14)
                Text(Tier.of(r.worst?.damage ?? 0).name).font(.system(size: 30, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(Tier.of(r.worst?.damage ?? 0).comment).font(.system(size: 14)).foregroundStyle(Color(red: 0.70, green: 0.75, blue: 0.89))
            }.padding(.top, 32)
            HStack(spacing: 0) {
                cardStat(L("累计使用", "Days in use"), L("\(r.days) 天", "\(r.days)"))
                Rectangle().fill(.white.opacity(0.20)).frame(width: 1, height: 35)
                cardStat(L("鼠标防护", "Cursor blocks"), r.blocks.formatted())
                Rectangle().fill(.white.opacity(0.20)).frame(width: 1, height: 35)
                cardStat(L("窗口避让", "Windows moved"), r.moves.formatted())
            }.padding(.top, 34)
            rule.padding(.vertical, 25)
            HStack(alignment: .firstTextBaseline) {
                Text(L("已获成就", "Earned Badges")).font(.system(size: 18, weight: .bold))
                Text("\(earnedCount)/\(Achievement.all.count)").font(.system(size: 16, weight: .medium, design: .rounded)).foregroundStyle(.white.opacity(0.8))
                Spacer()
                Image(systemName: "seal.fill").foregroundStyle(Color.cyan.opacity(0.7))
            }
            if badges.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "seal").font(.system(size: 38)).foregroundStyle(.white.opacity(0.45))
                    Text(L("第一枚徽章，等你点亮", "Your first badge is waiting")).font(.callout).foregroundStyle(.white.opacity(0.7))
                }.frame(maxWidth: .infinity).padding(.vertical, 25)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: min(4, badges.count)), alignment: .center, spacing: 20) {
                    ForEach(badges) { a in
                        VStack(spacing: 10) {
                            AchievementMedal(a: a, size: 76)
                            Text(a.title).font(.system(size: 12, weight: .semibold)).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                        }.frame(maxWidth: .infinity, alignment: .top)
                    }
                }.padding(.top, 23)
                Text(L("每条主线展示最高已解锁徽章", "Highest earned badge from each track")).font(.system(size: 10)).foregroundStyle(.white.opacity(0.45)).padding(.top, 17)
            }
            rule.padding(.vertical, 24)
            HStack {
                Text(L("坚持时间", "Time in Use")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text(AchievementTrack.time.next(r).map { L("正在迈向 \($0.desc.replacingOccurrences(of: "用坏屏幕 ", with: ""))", "Next: \($0.title)") } ?? L("全部解锁", "All unlocked"))
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
            }
            MilestoneBar(track: .time, report: r).padding(.top, 20)
            VStack(spacing: 12) {
                Text(L("坏屏也能继续发光。", "Still shining, cracks and all."))
                    .font(.system(size: 20, weight: .medium, design: .serif)).tracking(2)
                    .shadow(color: .purple.opacity(0.9), radius: 14)
                Text("github.com/prefect12/DeadZone").font(.system(size: 9)).foregroundStyle(.white.opacity(0.42))
            }.frame(maxWidth: .infinity).padding(.top, 44).padding(.bottom, 15)
        }
        .padding(26).frame(width: 440)
        .foregroundStyle(.white)
        .background {
            GeometryReader { geometry in
                if let image = CardArtwork.backdrop {
                    Image(nsImage: image).resizable().scaledToFill().frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else {
                    LinearGradient(colors: [Color(red: 0.02, green: 0.04, blue: 0.14), Color(red: 0.14, green: 0.09, blue: 0.32)], startPoint: .top, endPoint: .bottom)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(LinearGradient(colors: [Color(red: 0.43, green: 0.52, blue: 1), .blue.opacity(0.2), .purple.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2))
        .environment(\.colorScheme, .dark)
    }
    private var rule: some View {
        Rectangle().fill(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.12)], startPoint: .leading, endPoint: .trailing)).frame(height: 0.7)
    }
    private func cardStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 7) {
            Text(value).font(.system(size: 23, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 12)).foregroundStyle(Color(red: 0.67, green: 0.73, blue: 0.89))
        }.frame(maxWidth: .infinity)
    }
}

struct StatsView: View {
    let report: Report
    @State private var copied = false
    @State private var copyFailed = false
    @State private var selected: Achievement?
    @State private var cardImage: NSImage?
    @State private var renderFailed = false

    // Render once per displayed report; the preview and clipboard use the very same image.
    private var cardKey: String {
        "\(report.days)|\(report.blocks)|\(report.moves)|\(report.worst?.damage ?? 0)|" + report.unlocked.keys.sorted().joined(separator: ",")
    }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                achievementList.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                previewPanel.frame(width: min(440, max(330, geometry.size.width * 0.37)))
            }
        }
        .task(id: cardKey) { renderCard() }
        .sheet(item: $selected) { a in AchievementDetail(a: a, date: report.unlocked[a.id], report: report) }
        .alert(L("卡片未能复制", "Couldn't copy the card"), isPresented: $copyFailed) { Button(L("好", "OK")) {} }
    }

    private var achievementList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(L("每一次坚持，都值得一枚徽章", "Every milestone deserves a badge")).font(.headline)
                }
                HStack(spacing: 8) {
                    StatTile(label: L("累计使用", "Days in use"), value: L("\(report.days) 天", "\(report.days)"))
                    StatTile(label: L("鼠标防护", "Cursor blocks"), value: report.blocks.formatted())
                    StatTile(label: L("窗口避让", "Windows moved"), value: report.moves.formatted())
                    StatTile(label: L("成就解锁", "Unlocked"), value: "\(Achievement.all.filter { report.unlocked[$0.id] != nil }.count)/\(Achievement.all.count)")
                }
                Text(L("主线成就", "Achievement Tracks")).font(.headline)
                ForEach(AchievementTrack.allCases) { track in
                    TrackCard(track: track, report: report) { selected = $0 }
                }
                Text(L("独立成就", "Individual Achievements")).font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 10)], spacing: 10) {
                    ForEach(AchievementTrack.independent) { a in
                        Button { selected = a } label: { BadgeView(a: a, date: report.unlocked[a.id]) }.buttonStyle(.plain)
                    }
                }
                DisclosureGroup(L("屏幕战况", "Screen Details")) {
                    if report.screens.isEmpty { Text(L("还没有标记坏区", "No dead zones yet")).foregroundStyle(.secondary) }
                    ForEach(report.screens) { DamageCard(s: $0) }
                }
                Text(L("所有统计只保存在本机，不联网。", "All stats stay on this Mac. Nothing goes online.")).font(.caption2).foregroundStyle(.secondary)
            }.padding(22)
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("战绩卡片预览", "Stats Card Preview")).font(.headline)
                Spacer()
                Button { copyCard() } label: {
                    Label(copied ? L("已复制", "Copied") : L("复制", "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }.buttonStyle(.bordered).disabled(cardImage == nil)
            }
            if let image = cardImage {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 5)
                    .accessibilityLabel(L("战绩卡片，包含损坏面积、使用统计和已解锁徽章", "Stats card with screen damage, usage and earned badges"))
            } else if renderFailed {
                VStack(spacing: 12) {
                    Text(L("卡片暂时无法生成", "Couldn't generate the card")).foregroundStyle(.secondary)
                    Button(L("重试", "Retry")) { renderCard() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .padding(18)
        .background(LinearGradient(colors: [Color(red: 0.08, green: 0.10, blue: 0.15), Color(red: 0.04, green: 0.055, blue: 0.10)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
    }

    @MainActor private func renderCard() {
        copied = false
        let renderer = ImageRenderer(content: ShareCard(r: report))
        renderer.scale = 2
        cardImage = renderer.nsImage
        renderFailed = cardImage == nil
    }
    @MainActor private func copyCard() {
        guard let img = cardImage else { copyFailed = true; return }
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.writeObjects([img]) else { copyFailed = true; return }
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
