import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Known workout types (catalog lockstep)
//
// Raw values match `WorkoutCatalog.all` / Android `WorkoutSport.all` display names exactly.
// Free-text sports resolve into these cases (or the unknown fallback) so UI never switches on
// ad-hoc strings. When the catalogue gains a sport, add a case here in the same PR.

/// Every named sport the workout pickers suggest. Exhaustive for iconography.
public enum KnownWorkoutType: String, CaseIterable, Sendable {
    case running = "Running"
    case walking = "Walking"
    case hiking = "Hiking"
    case cycling = "Cycling"
    case openWaterSwim = "Open-water swim"
    case rowing = "Rowing"
    case treadmillRun = "Treadmill run"
    case treadmillWalk = "Treadmill walk"
    case indoorCycle = "Indoor cycle"
    case poolSwim = "Pool swim"
    case rowMachine = "Row machine"
    case elliptical = "Elliptical"
    case strength = "Strength"
    case bodybuilding = "Bodybuilding"
    case weightlifting = "Weightlifting"
    case hiit = "HIIT"
    case yoga = "Yoga"
    case pilates = "Pilates"
    case boxing = "Boxing"
    case basketball = "Basketball"
    case soccer = "Soccer"
    case baseball = "Baseball"
    case badminton = "Badminton"
    case tennis = "Tennis"
    case squash = "Squash"
    case racquetball = "Racquetball"
    case tableTennis = "Table tennis"
    case volleyball = "Volleyball"
    case martialArts = "Martial arts"
    case dancing = "Dancing"
    case golf = "Golf"
    case climbing = "Climbing"
    case stretching = "Stretching"
    case skiing = "Skiing"
    case snowboarding = "Snowboarding"
    case padel = "Padel"
    case pickleball = "Pickleball"
    case bowling = "Bowling"
    case other = "Other"

    /// Case-insensitive exact match against a stored/free-typed sport label.
    public static func exact(matching name: String) -> KnownWorkoutType? {
        let q = name.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return nil }
        return allCases.first { $0.rawValue.caseInsensitiveCompare(q) == .orderedSame }
    }

    /// Best-effort resolve for free-text labels that are not exact catalogue names.
    public static func resolving(_ sport: String) -> KnownWorkoutType? {
        if let exact = exact(matching: sport) { return exact }
        let s = sport.lowercased()
        // Order matters: more specific tokens before broader ones (padel before tennis, treadmill before run).
        switch true {
        case s.contains("treadmill") && s.contains("walk"): return .treadmillWalk
        case s.contains("treadmill"):                       return .treadmillRun
        case s.contains("open") && s.contains("swim"):      return .openWaterSwim
        case s.contains("pool") && s.contains("swim"):      return .poolSwim
        case s.contains("indoor") && (s.contains("cycl") || s.contains("bike")):
                                                            return .indoorCycle
        case s.contains("row") && (s.contains("machine") || s.contains("indoor") || s.contains("erg")):
                                                            return .rowMachine
        case s.contains("pickle"):                          return .pickleball
        case s.contains("padel"):                           return .padel
        case s.contains("racquet"):                         return .racquetball
        case s.contains("table") && s.contains("tennis"):   return .tableTennis
        case s.contains("badminton"):                       return .badminton
        case s.contains("squash"):                          return .squash
        case s.contains("tennis"):                          return .tennis
        case s.contains("snowboard"):                       return .snowboarding
        case s.contains("ski"):                             return .skiing
        case s.contains("hike") || s.contains("hiking"):    return .hiking
        case s.contains("walk"):                            return .walking
        case s.contains("run"):                             return .running
        case s.contains("cycl") || s.contains("bike") || s.contains("ride"):
                                                            return .cycling
        case s.contains("swim"):                            return .poolSwim
        case s.contains("row"):                             return .rowing
        case s.contains("elliptical"):                      return .elliptical
        case s.contains("bodybuild"):                       return .bodybuilding
        case s.contains("weightlift") || s.contains("olympic"):
                                                            return .weightlifting
        case s.contains("strength") || s.contains("weight") || s.contains("lift"):
                                                            return .strength
        case s.contains("hiit") || s.contains("interval"):  return .hiit
        case s.contains("yoga"):                            return .yoga
        case s.contains("pilates"):                         return .pilates
        case s.contains("box"):                             return .boxing
        case s.contains("basket"):                          return .basketball
        case s.contains("soccer") || s.contains("football"): return .soccer
        case s.contains("baseball"):                        return .baseball
        case s.contains("volley"):                          return .volleyball
        case s.contains("martial") || s.contains("jiu") || s.contains("judo")
            || s.contains("karate") || s.contains("mma"):   return .martialArts
        case s.contains("dance"):                           return .dancing
        case s.contains("golf"):                            return .golf
        case s.contains("climb"):                           return .climbing
        case s.contains("stretch") || s.contains("mobility") || s.contains("flex"):
                                                            return .stretching
        case s.contains("bowl"):                            return .bowling
        case s.contains("other") || s.contains("activity") || s.contains("detected"):
                                                            return .other
        default:                                            return nil
        }
    }
}

// MARK: - Iconography (central mapping)

/// Resolves a unique monochrome icon for each known workout type. Prefer SF Symbols; draw a custom
/// vector when no suitable (or available) system symbol exists so types never share a glyph.
public enum WorkoutTypeIconography {

    public enum Glyph: Equatable, Sendable {
        case system(String)
        case custom(Custom)
    }

    public enum Custom: String, CaseIterable, Equatable, Sendable {
        case padelRacket
        case pickleballPaddle
        case squashRacket
        case racquetballRacket
        case tableTennisPaddle
        case shuttlecock
        case treadmillRunBadge
        case treadmillWalkBadge
        case indoorCycleBadge
        case rowMachineBadge
        case ellipticalBadge
        case bodybuildingBadge
        case barbellBadge
        case snowboardBadge
        case openWaterWaves
        case hikingStick
    }

    /// Exhaustive per-type glyph. Preferred SF Symbol when present on the OS; otherwise a unique
    /// custom vector — never borrow another type's primary system name.
    public static func glyph(for type: KnownWorkoutType) -> Glyph {
        switch type {
        case .running:
            return .system("figure.run")
        case .walking:
            return .system("figure.walk")
        case .hiking:
            return systemOrCustom("figure.hiking", .hikingStick)
        case .cycling:
            return systemOrCustom("figure.outdoor.cycle", fallbackSystem: "bicycle")
        case .openWaterSwim:
            return systemOrCustom("figure.open.water.swim", .openWaterWaves)
        case .rowing:
            return systemOrCustom("figure.outdoor.rowing", fallbackSystem: "figure.rower")
        case .treadmillRun:
            return systemOrCustom("figure.run.treadmill", .treadmillRunBadge)
        case .treadmillWalk:
            return systemOrCustom("figure.walk.treadmill", .treadmillWalkBadge)
        case .indoorCycle:
            return systemOrCustom("figure.indoor.cycle", .indoorCycleBadge)
        case .poolSwim:
            return .system("figure.pool.swim")
        case .rowMachine:
            return systemOrCustom("figure.indoor.rowing", .rowMachineBadge)
        case .elliptical:
            return systemOrCustom("figure.elliptical", .ellipticalBadge)
        case .strength:
            return systemOrCustom("dumbbell.fill", fallbackSystem: "dumbbell")
        case .bodybuilding:
            return systemOrCustom("figure.strengthtraining.traditional", .bodybuildingBadge)
        case .weightlifting:
            return systemOrCustom("figure.strengthtraining.functional", .barbellBadge)
        case .hiit:
            return systemOrCustom("figure.highintensity.intervaltraining", fallbackSystem: "bolt.fill")
        case .yoga:
            return systemOrCustom("figure.yoga", fallbackSystem: "figure.mind.and.body")
        case .pilates:
            return systemOrCustom("figure.pilates", fallbackSystem: "figure.flexibility")
        case .boxing:
            return .system("figure.boxing")
        case .basketball:
            return systemOrCustom("figure.basketball", fallbackSystem: "basketball.fill")
        case .soccer:
            return systemOrCustom("figure.outdoor.soccer", fallbackSystem: "soccerball")
        case .baseball:
            return systemOrCustom("figure.baseball", fallbackSystem: "baseball.fill")
        case .badminton:
            return systemOrCustom("figure.badminton", .shuttlecock)
        case .tennis:
            return .system("figure.tennis")
        case .squash:
            return systemOrCustom("figure.squash", .squashRacket)
        case .racquetball:
            return systemOrCustom("figure.racquetball", .racquetballRacket)
        case .tableTennis:
            return systemOrCustom("figure.table.tennis", .tableTennisPaddle)
        case .volleyball:
            return .system("figure.volleyball")
        case .martialArts:
            return .system("figure.martial.arts")
        case .dancing:
            return .system("figure.dance")
        case .golf:
            return .system("figure.golf")
        case .climbing:
            return .system("figure.climbing")
        case .stretching:
            return .system("figure.flexibility")
        case .skiing:
            return systemOrCustom("figure.skiing.downhill", fallbackSystem: "figure.skiing.crosscountry")
        case .snowboarding:
            return systemOrCustom("figure.snowboarding", .snowboardBadge)
        case .padel:
            return .custom(.padelRacket)
        case .pickleball:
            return systemOrCustom("figure.pickleball", .pickleballPaddle)
        case .bowling:
            return .system("figure.bowling")
        case .other:
            return .system("figure.mixed.cardio")
        }
    }

    /// Preferred glyph identity ignoring OS availability — used to assert catalogue uniqueness.
    public static func preferredIdentity(for type: KnownWorkoutType) -> String {
        switch type {
        case .running:          return "system:figure.run"
        case .walking:          return "system:figure.walk"
        case .hiking:           return "system:figure.hiking"
        case .cycling:          return "system:figure.outdoor.cycle"
        case .openWaterSwim:    return "system:figure.open.water.swim"
        case .rowing:           return "system:figure.outdoor.rowing"
        case .treadmillRun:     return "system:figure.run.treadmill"
        case .treadmillWalk:    return "system:figure.walk.treadmill"
        case .indoorCycle:      return "system:figure.indoor.cycle"
        case .poolSwim:         return "system:figure.pool.swim"
        case .rowMachine:       return "system:figure.indoor.rowing"
        case .elliptical:       return "system:figure.elliptical"
        case .strength:         return "system:dumbbell.fill"
        case .bodybuilding:     return "system:figure.strengthtraining.traditional"
        case .weightlifting:    return "system:figure.strengthtraining.functional"
        case .hiit:             return "system:figure.highintensity.intervaltraining"
        case .yoga:             return "system:figure.yoga"
        case .pilates:          return "system:figure.pilates"
        case .boxing:           return "system:figure.boxing"
        case .basketball:       return "system:figure.basketball"
        case .soccer:           return "system:figure.outdoor.soccer"
        case .baseball:         return "system:figure.baseball"
        case .badminton:        return "system:figure.badminton"
        case .tennis:           return "system:figure.tennis"
        case .squash:           return "system:figure.squash"
        case .racquetball:      return "system:figure.racquetball"
        case .tableTennis:      return "system:figure.table.tennis"
        case .volleyball:       return "system:figure.volleyball"
        case .martialArts:      return "system:figure.martial.arts"
        case .dancing:          return "system:figure.dance"
        case .golf:             return "system:figure.golf"
        case .climbing:         return "system:figure.climbing"
        case .stretching:       return "system:figure.flexibility"
        case .skiing:           return "system:figure.skiing.downhill"
        case .snowboarding:     return "system:figure.snowboarding"
        case .padel:            return "custom:padelRacket"
        case .pickleball:       return "system:figure.pickleball"
        case .bowling:          return "system:figure.bowling"
        case .other:            return "system:figure.mixed.cardio"
        }
    }

    /// Runtime glyph identity (after availability resolution).
    public static func identity(for type: KnownWorkoutType) -> String {
        switch glyph(for: type) {
        case .system(let name): return "system:\(name)"
        case .custom(let custom): return "custom:\(custom.rawValue)"
        }
    }

    /// SF Symbol name for call sites that still need `Image(systemName:)`. Custom-only types return
    /// the nearest system stand-in so charts/lists stay populated.
    public static func systemSymbolName(for sport: String) -> String {
        let type = KnownWorkoutType.resolving(sport) ?? .other
        switch glyph(for: type) {
        case .system(let name):
            return name
        case .custom(.padelRacket), .custom(.pickleballPaddle), .custom(.squashRacket),
             .custom(.racquetballRacket), .custom(.tableTennisPaddle), .custom(.shuttlecock):
            return "figure.tennis"
        case .custom(.treadmillRunBadge):
            return "figure.run"
        case .custom(.treadmillWalkBadge):
            return "figure.walk"
        case .custom(.indoorCycleBadge):
            return "bicycle"
        case .custom(.rowMachineBadge):
            return "figure.rower"
        case .custom(.ellipticalBadge):
            return "figure.mixed.cardio"
        case .custom(.bodybuildingBadge):
            return "dumbbell.fill"
        case .custom(.barbellBadge):
            return "dumbbell"
        case .custom(.snowboardBadge):
            return "figure.skiing.downhill"
        case .custom(.openWaterWaves):
            return "figure.pool.swim"
        case .custom(.hikingStick):
            return "figure.walk"
        }
    }

    private static func systemOrCustom(_ preferred: String, _ custom: Custom) -> Glyph {
        systemSymbolExists(preferred) ? .system(preferred) : .custom(custom)
    }

    private static func systemOrCustom(_ preferred: String, fallbackSystem: String) -> Glyph {
        if systemSymbolExists(preferred) { return .system(preferred) }
        if systemSymbolExists(fallbackSystem) { return .system(fallbackSystem) }
        return .system(preferred)
    }

    private static func systemSymbolExists(_ name: String) -> Bool {
        #if canImport(UIKit)
        return UIImage(systemName: name) != nil
        #elseif canImport(AppKit)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        #else
        return true
        #endif
    }
}

// MARK: - WorkoutTypeIcon

/// Monochrome workout-type glyph for Liquid Glass controls, lists, and badges.
public struct WorkoutTypeIcon: View {
    private let sport: String
    private let size: CGFloat
    private let weight: Font.Weight
    private let color: Color

    public init(workoutType: String,
                size: CGFloat = 22,
                weight: Font.Weight = .medium,
                color: Color = StrandPalette.textPrimary) {
        self.sport = workoutType
        self.size = size
        self.weight = weight
        self.color = color
    }

    public init(workoutType: KnownWorkoutType,
                size: CGFloat = 22,
                weight: Font.Weight = .medium,
                color: Color = StrandPalette.textPrimary) {
        self.sport = workoutType.rawValue
        self.size = size
        self.weight = weight
        self.color = color
    }

    public var body: some View {
        let type = KnownWorkoutType.resolving(sport) ?? .other
        Group {
            switch WorkoutTypeIconography.glyph(for: type) {
            case .system(let name):
                Image(systemName: name)
                    .font(.system(size: size, weight: weight))
                    .symbolRenderingMode(.monochrome)
            case .custom(let custom):
                customStroke(custom)
            }
        }
        .foregroundStyle(color)
        .frame(width: size, height: size, alignment: .center)
        .accessibilityHidden(true)
    }

    private var strokeWidth: CGFloat { max(1.35, size * 0.085) }

    @ViewBuilder
    private func customStroke(_ custom: WorkoutTypeIconography.Custom) -> some View {
        let style = StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
        Group {
            switch custom {
            case .padelRacket:        PadelRacketShape().stroke(style: style)
            case .pickleballPaddle:   PickleballPaddleShape().stroke(style: style)
            case .squashRacket:       SquashRacketShape().stroke(style: style)
            case .racquetballRacket:  RacquetballRacketShape().stroke(style: style)
            case .tableTennisPaddle:  TableTennisPaddleShape().stroke(style: style)
            case .shuttlecock:        ShuttlecockShape().stroke(style: style)
            case .treadmillRunBadge:  TreadmillBadgeShape(kind: .run).stroke(style: style)
            case .treadmillWalkBadge: TreadmillBadgeShape(kind: .walk).stroke(style: style)
            case .indoorCycleBadge:   IndoorCycleBadgeShape().stroke(style: style)
            case .rowMachineBadge:    RowMachineBadgeShape().stroke(style: style)
            case .ellipticalBadge:    EllipticalBadgeShape().stroke(style: style)
            case .bodybuildingBadge:  BodybuildingBadgeShape().stroke(style: style)
            case .barbellBadge:       BarbellBadgeShape().stroke(style: style)
            case .snowboardBadge:     SnowboardBadgeShape().stroke(style: style)
            case .openWaterWaves:     OpenWaterWavesShape().stroke(style: style)
            case .hikingStick:        HikingStickShape().stroke(style: style)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Custom vectors (SF-Symbol weight / centering)

struct PadelRacketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX
        var path = Path()
        let headW = s * 0.62
        let headH = s * 0.56
        let headRect = CGRect(x: cx - headW / 2, y: rect.minY + s * 0.05,
                              width: headW, height: headH)
        path.addRoundedRect(in: headRect, cornerSize: CGSize(width: headW * 0.28, height: headH * 0.28))
        path.move(to: CGPoint(x: cx, y: headRect.maxY - s * 0.02))
        path.addLine(to: CGPoint(x: cx, y: rect.minY + s * 0.90))
        let butt = s * 0.14
        path.addEllipse(in: CGRect(x: cx - butt / 2, y: rect.minY + s * 0.84,
                                   width: butt, height: s * 0.10))
        let r = s * 0.04
        for (dx, dy) in [(-0.12, 0.22), (0.12, 0.22), (0.0, 0.36)] as [(CGFloat, CGFloat)] {
            path.addEllipse(in: CGRect(x: cx + dx * s - r, y: rect.minY + dy * s - r,
                                       width: r * 2, height: r * 2))
        }
        return path
    }
}

struct PickleballPaddleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX
        var path = Path()
        let headW = s * 0.58
        let headH = s * 0.50
        let headRect = CGRect(x: cx - headW / 2, y: rect.minY + s * 0.06,
                              width: headW, height: headH)
        path.addRoundedRect(in: headRect, cornerSize: CGSize(width: headW * 0.22, height: headH * 0.22))
        path.move(to: CGPoint(x: cx, y: headRect.maxY))
        path.addLine(to: CGPoint(x: cx, y: rect.minY + s * 0.88))
        // Perforated ball to the side of the paddle.
        let ballR = s * 0.11
        path.addEllipse(in: CGRect(x: cx + s * 0.22, y: rect.minY + s * 0.55,
                                   width: ballR * 2, height: ballR * 2))
        return path
    }
}

struct SquashRacketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX
        var path = Path()
        // Teardrop squash head (taller / narrower than tennis).
        let head = CGRect(x: cx - s * 0.22, y: rect.minY + s * 0.04,
                          width: s * 0.44, height: s * 0.55)
        path.addEllipse(in: head)
        path.move(to: CGPoint(x: cx, y: head.maxY - s * 0.02))
        path.addLine(to: CGPoint(x: cx, y: rect.minY + s * 0.92))
        // Small ball near throat.
        let r = s * 0.07
        path.addEllipse(in: CGRect(x: cx + s * 0.18, y: head.midY, width: r * 2, height: r * 2))
        return path
    }
}

struct TreadmillBadgeShape: Shape {
    enum Kind { case run, walk }
    var kind: Kind

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        var path = Path()
        // Deck
        path.move(to: CGPoint(x: rect.minX + s * 0.08, y: rect.minY + s * 0.72))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.92, y: rect.minY + s * 0.72))
        // Console upright
        path.move(to: CGPoint(x: rect.minX + s * 0.78, y: rect.minY + s * 0.72))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.78, y: rect.minY + s * 0.28))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.58, y: rect.minY + s * 0.28))
        // Figure cue — forward lean for run, upright for walk.
        let figureX = rect.minX + s * 0.38
        let headY = kind == .run ? rect.minY + s * 0.30 : rect.minY + s * 0.26
        path.addEllipse(in: CGRect(x: figureX - s * 0.07, y: headY, width: s * 0.14, height: s * 0.14))
        path.move(to: CGPoint(x: figureX, y: headY + s * 0.14))
        path.addLine(to: CGPoint(x: figureX + (kind == .run ? s * 0.06 : 0),
                                 y: rect.minY + s * 0.58))
        return path
    }
}

struct OpenWaterWavesShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        var path = Path()
        for i in 0..<3 {
            let y = rect.minY + s * (0.30 + CGFloat(i) * 0.22)
            path.move(to: CGPoint(x: rect.minX + s * 0.10, y: y))
            path.addQuadCurve(to: CGPoint(x: rect.minX + s * 0.50, y: y),
                              control: CGPoint(x: rect.minX + s * 0.30, y: y - s * 0.10))
            path.addQuadCurve(to: CGPoint(x: rect.minX + s * 0.90, y: y),
                              control: CGPoint(x: rect.minX + s * 0.70, y: y + s * 0.10))
        }
        return path
    }
}

struct HikingStickShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + s * 0.62, y: rect.minY + s * 0.08))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.38, y: rect.minY + s * 0.92))
        path.addEllipse(in: CGRect(x: rect.minX + s * 0.22, y: rect.minY + s * 0.18,
                                   width: s * 0.16, height: s * 0.16))
        path.move(to: CGPoint(x: rect.minX + s * 0.30, y: rect.minY + s * 0.34))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.30, y: rect.minY + s * 0.62))
        path.move(to: CGPoint(x: rect.minX + s * 0.30, y: rect.minY + s * 0.62))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.18, y: rect.minY + s * 0.82))
        path.move(to: CGPoint(x: rect.minX + s * 0.30, y: rect.minY + s * 0.62))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.44, y: rect.minY + s * 0.82))
        return path
    }
}

struct RacquetballRacketShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX
        var path = Path()
        let head = CGRect(x: cx - s * 0.28, y: rect.minY + s * 0.06, width: s * 0.56, height: s * 0.48)
        path.addEllipse(in: head)
        path.move(to: CGPoint(x: cx, y: head.maxY))
        path.addLine(to: CGPoint(x: cx, y: rect.minY + s * 0.92))
        let r = s * 0.08
        path.addEllipse(in: CGRect(x: cx + s * 0.20, y: head.midY - r, width: r * 2, height: r * 2))
        return path
    }
}

struct TableTennisPaddleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX
        var path = Path()
        let head = CGRect(x: cx - s * 0.30, y: rect.minY + s * 0.08, width: s * 0.56, height: s * 0.50)
        path.addEllipse(in: head)
        path.move(to: CGPoint(x: cx - s * 0.02, y: head.maxY - s * 0.02))
        path.addLine(to: CGPoint(x: cx - s * 0.08, y: rect.minY + s * 0.92))
        let r = s * 0.07
        path.addEllipse(in: CGRect(x: cx + s * 0.22, y: head.maxY - r, width: r * 2, height: r * 2))
        return path
    }
}

struct ShuttlecockShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX
        var path = Path()
        // Cork
        path.addEllipse(in: CGRect(x: cx - s * 0.12, y: rect.minY + s * 0.62, width: s * 0.24, height: s * 0.22))
        // Skirt feathers
        for dx in [-0.28, -0.14, 0.0, 0.14, 0.28] as [CGFloat] {
            path.move(to: CGPoint(x: cx, y: rect.minY + s * 0.68))
            path.addLine(to: CGPoint(x: cx + dx * s, y: rect.minY + s * 0.12))
        }
        return path
    }
}

struct IndoorCycleBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX + s * 0.18, y: rect.minY + s * 0.42,
                                   width: s * 0.64, height: s * 0.48))
        path.move(to: CGPoint(x: rect.minX + s * 0.50, y: rect.minY + s * 0.42))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.50, y: rect.minY + s * 0.18))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.72, y: rect.minY + s * 0.18))
        return path
    }
}

struct RowMachineBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        var path = Path()
        // Rail
        path.move(to: CGPoint(x: rect.minX + s * 0.08, y: rect.minY + s * 0.70))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.92, y: rect.minY + s * 0.70))
        // Seat
        path.addRoundedRect(in: CGRect(x: rect.minX + s * 0.30, y: rect.minY + s * 0.52,
                                       width: s * 0.28, height: s * 0.14),
                            cornerSize: CGSize(width: 3, height: 3))
        // Flywheel
        path.addEllipse(in: CGRect(x: rect.minX + s * 0.68, y: rect.minY + s * 0.38,
                                   width: s * 0.24, height: s * 0.24))
        return path
    }
}

struct EllipticalBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        var path = Path()
        path.addEllipse(in: CGRect(x: rect.minX + s * 0.12, y: rect.minY + s * 0.48,
                                   width: s * 0.76, height: s * 0.36))
        path.move(to: CGPoint(x: rect.minX + s * 0.28, y: rect.minY + s * 0.48))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.28, y: rect.minY + s * 0.20))
        path.move(to: CGPoint(x: rect.minX + s * 0.72, y: rect.minY + s * 0.48))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.72, y: rect.minY + s * 0.20))
        return path
    }
}

struct BodybuildingBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cx = rect.midX
        var path = Path()
        // Wide dumbbell — thicker plates than Strength's system glyph cue.
        path.addRoundedRect(in: CGRect(x: cx - s * 0.42, y: rect.minY + s * 0.38,
                                       width: s * 0.18, height: s * 0.24),
                            cornerSize: CGSize(width: 2, height: 2))
        path.addRoundedRect(in: CGRect(x: cx + s * 0.24, y: rect.minY + s * 0.38,
                                       width: s * 0.18, height: s * 0.24),
                            cornerSize: CGSize(width: 2, height: 2))
        path.move(to: CGPoint(x: cx - s * 0.24, y: rect.midY))
        path.addLine(to: CGPoint(x: cx + s * 0.24, y: rect.midY))
        return path
    }
}

struct BarbellBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let cy = rect.midY
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + s * 0.06, y: cy))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.94, y: cy))
        for x in [0.16, 0.28, 0.72, 0.84] as [CGFloat] {
            path.addRect(CGRect(x: rect.minX + s * x - s * 0.04, y: cy - s * 0.18,
                                width: s * 0.08, height: s * 0.36))
        }
        return path
    }
}

struct SnowboardBadgeShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        var path = Path()
        path.addRoundedRect(in: CGRect(x: rect.minX + s * 0.18, y: rect.minY + s * 0.12,
                                       width: s * 0.28, height: s * 0.76),
                            cornerSize: CGSize(width: s * 0.14, height: s * 0.14))
        path.move(to: CGPoint(x: rect.minX + s * 0.46, y: rect.minY + s * 0.35))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.70, y: rect.minY + s * 0.22))
        path.move(to: CGPoint(x: rect.minX + s * 0.46, y: rect.minY + s * 0.55))
        path.addLine(to: CGPoint(x: rect.minX + s * 0.78, y: rect.minY + s * 0.70))
        return path
    }
}

// MARK: - Legacy `sportSymbol` bridge

/// The SF Symbol that best represents a free-text `sport` label. Shared so a sport reads identically
/// in lists/charts that still take `Image(systemName:)`. Prefer `WorkoutTypeIcon` for new surfaces.
public func sportSymbol(_ sport: String) -> String {
    WorkoutTypeIconography.systemSymbolName(for: sport)
}

#if DEBUG
#Preview("Workout type icons") {
    ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 16) {
            ForEach(KnownWorkoutType.allCases, id: \.rawValue) { type in
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(StrandPalette.surfaceRaised)
                        WorkoutTypeIcon(workoutType: type, size: 22, weight: .semibold)
                    }
                    .frame(width: 56, height: 56)
                    Text(type.rawValue)
                        .font(.caption2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding()
    }
    .background(StrandPalette.surfaceBase)
}
#endif
