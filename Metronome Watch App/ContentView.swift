import SwiftUI
import WatchKit
import Combine
#if canImport(CoreHaptics)
import CoreHaptics
#endif

// MARK: - Haptics
final class HapticsManager {
    #if canImport(CoreHaptics)
    private var engine: CHHapticEngine?
    private var supportsHaptics = false
    #endif
    /// NEW: 是否使用“短促手感”
    var useShortPreset = true


    init() {
        #if canImport(CoreHaptics)
        supportsHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        if supportsHaptics {
            engine = try? CHHapticEngine()
            try? engine?.start()
        }
        #endif
    }

    func playBeat(accent: Bool) {
        #if canImport(CoreHaptics)
        if supportsHaptics {
            do {
                if useShortPreset {
                    // 短促&干脆的触感（重音稍长一点点，仍很利落）
                    let duration: TimeInterval = accent ? 0.028 : 0.018
                    let intensity: Float        = accent ? 0.70  : 0.45
                    let sharpness: Float        = accent ? 0.95  : 0.60

                    let event = CHHapticEvent(
                        eventType: .hapticContinuous,
                        parameters: [
                            .init(parameterID: .hapticIntensity, value: intensity),
                            .init(parameterID: .hapticSharpness, value: sharpness)
                        ],
                        relativeTime: 0,
                        duration: duration
                    )
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    let player = try engine?.makePlayer(with: pattern)
                    try player?.start(atTime: 0)
                    return
                } else {
                    // 原方案（瞬态 + 重音回声）
                    let intensity: Float = accent ? 1.0 : 0.35
                    let sharpness: Float = accent ? 0.9 : 0.4
                    var events = [CHHapticEvent(eventType: .hapticTransient,
                                                parameters: [
                                                    .init(parameterID: .hapticIntensity, value: intensity),
                                                    .init(parameterID: .hapticSharpness, value: sharpness)
                                                ],
                                                relativeTime: 0)]
                    if accent {
                        events.append(CHHapticEvent(eventType: .hapticTransient,
                                                    parameters: [
                                                        .init(parameterID: .hapticIntensity, value: 0.5),
                                                        .init(parameterID: .hapticSharpness, value: 0.6)
                                                    ],
                                                    relativeTime: 0.06))
                    }
                    let pattern = try CHHapticPattern(events: events, parameters: [])
                    let player = try engine?.makePlayer(with: pattern)
                    try player?.start(atTime: 0)
                    return
                }
            } catch {
                // fall through to fallback
            }
        }
        #endif
        // 模拟器/不支持 CoreHaptics：用系统触感
        if useShortPreset {
            WKInterfaceDevice.current().play(.click)              // 最短
        } else {
            WKInterfaceDevice.current().play(accent ? .directionUp : .click)
        }
    }
}

// MARK: - Metronome Engine (修复版本)
final class Metronome: ObservableObject {
    @Published var shortHaptics: Bool = true {
        didSet { haptics.useShortPreset = shortHaptics }
    }
    @Published var bpm: Int = 120 {
        didSet {
            let clampedBPM = min(max(bpm, 120), 300)
            if clampedBPM != bpm {
                bpm = clampedBPM
                return
            }
            rescheduleIfNeeded()
        }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var beatIndex: Int = 0

    let beatsPerBar: Int = 2

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "metronome.queue", qos: .userInteractive)
    private var startUptime: UInt64 = 0
    private var beatsElapsed: UInt64 = 0
    private let haptics = HapticsManager()
    
    // 添加锁来防止竞态条件
    private let timerLock = NSLock()
    
    init() {
        haptics.useShortPreset = shortHaptics
    }
    
    deinit {
        stop()
    }

    func start() {
        timerLock.lock()
        defer { timerLock.unlock() }
        
        guard !isRunning else { return }
        beatsElapsed = 0
        beatIndex = 0
        startUptime = DispatchTime.now().uptimeNanoseconds
        
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = true
        }
        
        scheduleTimer()
        tick() // 立即触发第一次节拍
    }

    func stop() {
        timerLock.lock()
        defer { timerLock.unlock() }
        
        guard isRunning else { return }
        
        timer?.cancel()
        timer = nil
        
        DispatchQueue.main.async { [weak self] in
            self?.isRunning = false
        }
    }

    func toggle() {
        isRunning ? stop() : start()
    }

    private func secondsPerBeat(_ bpm: Int) -> Double {
        60.0 / Double(bpm)
    }

    private func scheduleTimer() {
        // 确保在正确的队列上执行
        let spb = secondsPerBeat(bpm)
        let periodNs = UInt64(spb * 1_000_000_000)

        let newTimer = DispatchSource.makeTimerSource(queue: queue)
        newTimer.schedule(deadline: .now() + spb, repeating: .never, leeway: .nanoseconds(0))
        
        newTimer.setEventHandler { [weak self] in
            guard let self = self else { return }
            
            // 使用锁保护共享状态
            self.timerLock.lock()
            guard self.isRunning else {
                self.timerLock.unlock()
                return
            }
            self.timerLock.unlock()
            
            self.tick()
            self.beatsElapsed += 1
            
            let nextNs = self.startUptime + (self.beatsElapsed + 1) * periodNs
            let now = DispatchTime.now().uptimeNanoseconds
            
            var scheduled = nextNs
            if nextNs <= now {
                let behind = now - self.startUptime
                let beatsBehind = behind / periodNs
                self.beatsElapsed = beatsBehind
                scheduled = self.startUptime + (beatsBehind + 1) * periodNs
            }
            
            let delta = Double(scheduled - now) / 1_000_000_000
            if delta > 0 {
                newTimer.schedule(deadline: .now() + delta, repeating: .never, leeway: .nanoseconds(0))
            }
        }
        
        timer = newTimer
        newTimer.resume()
    }

    private func rescheduleIfNeeded() {
        timerLock.lock()
        defer { timerLock.unlock() }
        
        guard isRunning else { return }
        
        // 安全地取消旧定时器
        timer?.cancel()
        timer = nil
        
        // 重新开始计时
        startUptime = DispatchTime.now().uptimeNanoseconds
        beatsElapsed = 0
        scheduleTimer()
    }

    private func tick() {
        let indexInBar = Int(beatsElapsed % UInt64(beatsPerBar))
        
        DispatchQueue.main.async { [weak self] in
            self?.beatIndex = indexInBar
        }
        
        haptics.playBeat(accent: indexInBar == 0)
    }
}


// MARK: - SwiftUI UI
struct ContentView: View {
    @StateObject private var metro = Metronome()
    @StateObject private var wk = WorkoutKeeper()     // Workout 会话保活
    @Environment(\.scenePhase) private var scene
    @FocusState private var crownFocused: Bool   // 新增：让数字表冠有焦点

    // 半透明主色（Start/Stop & Tap 的色板）
    private let playTint = Color(red: 52/255, green: 199/255, blue: 89/255) // #34C759
//    private let playTint = Color(red: 0.631, green: 0.965, blue: 0.020) // #A1F605
//    private let playTint  = Color(red: 0.000, green: 0.749, blue: 0.388).opacity(0.72) // #00BF63 × 72%
    private let stopTint  = Color(red: 0.950, green: 0.230, blue: 0.260).opacity(0.72) // 柔和红 × 72%
    private let tapTint   = Color.white.opacity(0.26)                                  // Tap 用浅白 × 26%

    var body: some View {
        VStack(spacing: 8) {
            // NEW: 开关短促手感
            Toggle("短促手感", isOn: $metro.shortHaptics)
                .toggleStyle(.switch)
            // Beat LEDs
            HStack(spacing: 8) {
                ForEach(0..<metro.beatsPerBar, id: \.self) { i in
                    Circle()
                        .fill(metro.beatIndex == i && metro.isRunning ? Color.accentColor : Color.gray.opacity(0.3))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Text("\(i+1)")
                                .font(.caption2)
                                .foregroundStyle(.black.opacity(0.7))
                        )
                }
            }
            .padding(.top, 2)
            

            // BPM display
            Text("\(metro.bpm) BPM")
                .font(.system(size: 20, weight: .semibold))
                .monospacedDigit()

            // Crown-adjustable slider 120–300 bpm
            BPMDial(value: Binding(
                get: { Double(metro.bpm) },
                set: { metro.bpm = Int($0.rounded()) }
            ))
            .focusable(true)
            .focused($crownFocused)     // 新增：让 Crown 作用在拨盘上
            .digitalCrownRotation(
                Binding(
                    get: { Double(metro.bpm) },
                    set: { newVal in metro.bpm = Int(newVal.clamped(to: 120...300)) }
                ),
                from: 120, through: 300, by: 1, sensitivity: .medium, isHapticFeedbackEnabled: true
            )
            .frame(height: 10)

            // Controls
            HStack {
                Button(action: {
                    if metro.isRunning {
                        metro.toggle()  // stop
                        wk.stop()       // NEW: 停止 workout
                    } else {
                        try? wk.start() // NEW: 先开 workout（允许后台继续跑）
                        metro.toggle()  // start
                    }
                }) {
                    Label(metro.isRunning ? "Stop" : "Start",
                          systemImage: metro.isRunning ? "stop.circle.fill" : "play.circle.fill")
                }
                .labelStyle(.iconOnly)                       // ← 只显示图标，文字用于无障碍
                .accessibilityLabel(metro.isRunning ? "Stop" : "Start") // ← 读屏友好
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.roundedRectangle)
                .tint(metro.isRunning ? stopTint : playTint)
                .font(.system(size: 26, weight: .semibold))

//                Button(action: { tapTempo() }) {
//                    Label("Tap", systemImage: "hand.tap.fill")
//                }
//                .tint(tapTint)
//                .labelStyle(.iconOnly)
//                .font(.system(size: 26, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 16)
        .onAppear {
            crownFocused = true                     // 进入页面就把 Crown 焦点给拨盘
            Task { try? await wk.authorizeIfNeeded() }  // HealthKit 授权（Workout 需要）
        }
        .onChange(of: scene) { _, phase in
            if phase == .background, !wk.isActive { metro.stop() }
        }
    }

    // Simple tap-tempo: average last few taps
    @State private var lastTaps: [Date] = []
    private func tapTempo() {
        let now = Date()
        lastTaps.append(now)
        if lastTaps.count > 5 { lastTaps.removeFirst() }
        guard lastTaps.count >= 2 else { return }
        let intervals = zip(lastTaps.dropFirst(), lastTaps).map { $0.timeIntervalSince($1) }
        let avg = intervals.reduce(0,+) / Double(intervals.count)
        let newBPM = Int((60.0 / avg).rounded())
        // Clamp to supported range
        let clamped = min(max(newBPM, 120), 300)
        metro.bpm = clamped
    }
}

// MARK: - Dial UI
//struct BPMDial: View {
//    @Binding var value: Double
//    var body: some View {
//        GeometryReader { geo in
//            let w = geo.size.width
//            let progress = (value - 120) / (300 - 120)
//            ZStack(alignment: .leading) {
//                Capsule().fill(Color.gray.opacity(0.2))
//                Capsule()
//                    .fill(Color.accentColor)
//                    .frame(width: max(8, w * progress))
//            }
//            .overlay(alignment: .trailing) {
//                Circle().fill(Color.accentColor)
//                    .frame(width: 14, height: 14)
//            }
//        }
//    }
//}
// MARK: - Dial UI（可交互 + 触摸反馈）
//struct BPMDial: View {
//    @Binding var value: Double
//    @GestureState private var isInteracting = false   // 手指正在交互
//
//    private let minV: Double = 120
//    private let maxV: Double = 300
//
//    var body: some View {
//        GeometryReader { geo in
//            let w = geo.size.width
//            let h = geo.size.height
//            // 进度 0...1（保证边界）
//            let progress = CGFloat(((value - minV) / (maxV - minV)).clamped(to: 0...1))
//            let knobSize = max(10, h * 0.6)           // 把手随高度自适配
//            let knobCenterX = (w * progress).clamped(to: knobSize/2 ... w - knobSize/2)
//
//            ZStack(alignment: .leading) {
//                // 底轨
//                Capsule()
//                    .fill(Color.gray.opacity(isInteracting ? 0.15 : 0.22))
//
//                // 已走进度
//                Capsule()
//                    .fill(Color.accentColor.opacity(isInteracting ? 1.0 : 0.85))
//                    .frame(width: max(8, w * progress))
//            }
//            // 把手跟随进度移动
//            .overlay(alignment: .leading) {
//                Circle()
//                    .fill(Color.accentColor)
//                    .frame(width: knobSize, height: knobSize)
//                    .offset(x: knobCenterX - knobSize/2)
//                    .shadow(radius: isInteracting ? 1.5 : 0)
//                    .scaleEffect(isInteracting ? 1.08 : 1.0)
//                    .animation(.easeOut(duration: 0.12), value: isInteracting)
//            }
//            .contentShape(Rectangle()) // 整个区域都可点/拖
//            .gesture(
//                DragGesture(minimumDistance: 0)
//                    .updating($isInteracting) { _, s, _ in s = true }
//                    .onChanged { g in
//                        let x = max(0, min(w, g.location.x))
//                        let p = x / w
//                        let target = minV + Double(p) * (maxV - minV)
//                        value = round(target) // 步进 1 BPM；如果要更细可去掉 round
//                    }
//            )
//        }
//    }
//}

//// MARK: - Dial UI（可拖拽 + 交互时明显变亮）
//struct BPMDial: View {
//    @Binding var value: Double
//    @GestureState private var isInteracting = false   // 手指是否在交互
//
//    private let minV: Double = 120
//    private let maxV: Double = 300
//
//    var body: some View {
//        GeometryReader { geo in
//            let w = geo.size.width
//            let h = geo.size.height
//
//            let progress = CGFloat(((value - minV) / (maxV - minV)).clamped(to: 0...1))
//
//            // 交互时更亮、更饱和
//            let baseColor   = Color.white.opacity(isInteracting ? 0.18 : 0.08)
//            let activeColor = isInteracting ? Color.accentColor : Color.accentColor.opacity(0.65)
//
//            let knobSize = max(10, h * (isInteracting ? 0.70 : 0.60))
//            let knobX = (w * progress).clamped(to: knobSize/2 ... w - knobSize/2)
//
//            ZStack(alignment: .leading) {
//                // 底轨
//                Capsule()
//                    .fill(baseColor)
//
//                // 已走进度（交互时更亮，并轻微加厚）
//                Capsule()
//                    .fill(
//                        LinearGradient(colors: [activeColor, activeColor.opacity(0.85)],
//                                       startPoint: .leading, endPoint: .trailing)
//                    )
//                    .frame(width: max(8, w * progress),
//                           height: h * (isInteracting ? 1.08 : 1.0))
//            }
//            // 把手：交互时放大、加白描边与阴影
//            .overlay(alignment: .leading) {
//                Circle()
//                    .fill(activeColor)
//                    .overlay(
//                        Circle().stroke(Color.white.opacity(isInteracting ? 0.9 : 0.0), lineWidth: 1)
//                    )
//                    .frame(width: knobSize, height: knobSize)
//                    .offset(x: knobX - knobSize/2)
//                    .shadow(color: activeColor.opacity(isInteracting ? 0.6 : 0), radius: isInteracting ? 5 : 0)
//            }
//            .contentShape(Rectangle()) // 整个区域可点/拖
//            .gesture(
//                DragGesture(minimumDistance: 0)
//                    .updating($isInteracting) { _, s, _ in s = true }
//                    .onChanged { g in
//                        let x = max(0, min(w, g.location.x))
//                        let p = x / w
//                        let target = minV + Double(p) * (maxV - minV)
//                        value = round(target) // 步进 1BPM；去掉 round 则连续
//                    }
//            )
//            .animation(.easeOut(duration: 0.12), value: isInteracting)
//        }
//    }
//}

// MARK: - Dial UI（可拖拽 + 渐变  #00BF63 → #88ED6A）
struct BPMDial: View {
    @Binding var value: Double
    @GestureState private var isInteracting = false

    private let minV: Double = 120
    private let maxV: Double = 300

    // 渐变色（十六进制换算）
    private let endGreen = Color(red: 0.533, green: 0.929, blue: 0.416) // #88ED6A
    private let startGreen = Color(red: 0.000, green: 0.749, blue: 0.388) // #00BF63

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            let progress = CGFloat(((value - minV) / (maxV - minV)).clamped(to: 0...1))
            let knobSize = max(10, h * (isInteracting ? 0.70 : 0.60))
            let knobX = (w * progress).clamped(to: knobSize/2 ... w - knobSize/2)

            // 交互时整体更亮、进度略加厚
            let baseColor = Color.black.opacity(isInteracting ? 0.25 : 0.18)
            let fillOpacity = isInteracting ? 1.0 : 0.88

            ZStack(alignment: .leading) {
                // 底轨
                Capsule().fill(baseColor)

                // 已走进度（线性渐变）
                Capsule()
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                startGreen.opacity(fillOpacity),
                                endGreen.opacity(fillOpacity)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, w * progress),
                           height: h * (isInteracting ? 1.12 : 1.0))
            }
            // 把手（用结束色，交互时放大+白描边+荧光阴影）
            .overlay(alignment: .leading) {
                Circle()
                    .fill(endGreen)
                    .overlay(
                        Circle().stroke(Color.white.opacity(isInteracting ? 0.9 : 0.0), lineWidth: 1)
                    )
                    .frame(width: knobSize, height: knobSize)
                    .offset(x: knobX - knobSize/2)
                    .shadow(color: endGreen.opacity(isInteracting ? 0.9 : 0.5),
                            radius: isInteracting ? 6 : 3)
                    .scaleEffect(isInteracting ? 1.08 : 1.0)
            }
            .contentShape(Rectangle()) // 整块可点/拖
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($isInteracting) { _, s, _ in s = true }
                    .onChanged { g in
                        let x = max(0, min(w, g.location.x))
                        let p = x / w
                        let target = minV + Double(p) * (maxV - minV)
                        value = round(target) // 步进 1 BPM；去掉 round 可连贯
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isInteracting)
        }
    }
}


// MARK: - App Entry
//@main
//struct MetronomeApp: App {
//    var body: some Scene {
//        WindowGroup {
//            ContentView()
//        }
//    }
//}

// MARK: - Utilities
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
