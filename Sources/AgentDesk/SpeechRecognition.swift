import SwiftUI
import Speech
import AVFAudio

/// A user-started, on-device-only dictation controller. It never starts the
/// microphone from init or from a view appearing. The caller must invoke
/// `start(appendingTo:)` through an explicit button click.
@MainActor
public final class SpeechRecognitionController: NSObject, ObservableObject {
    public enum State: Equatable {
        case idle
        case requestingPermission
        case recording
        case stopped
        case unavailable
        case failed

        public var isRecording: Bool { self == .recording }
        public var isBusy: Bool { self == .recording || self == .requestingPermission }
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var transcript = ""
    @Published public private(set) var statusMessage = ""
    @Published public private(set) var errorMessage: String?

    @Published public private(set) var localeIdentifier: String
    public static let supportedLocaleIdentifiers = ["zh-CN", "en-GB", "en-US"]

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var timeoutTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var transcriptGeneration: UInt64 = 0
    fileprivate var transcriptIsCurrent: Bool { generation == transcriptGeneration }
    private var tapInstalled = false
    private var baseText = ""
    private let maximumSeconds: UInt64 = 60

    public init(localeIdentifier: String = "zh-CN") {
        self.localeIdentifier = Self.supportedLocaleIdentifiers.contains(localeIdentifier) ? localeIdentifier : "zh-CN"
        super.init()
        rebuildRecognizer()
        Self.register(self)
    }

    deinit {
        timeoutTask?.cancel()
        permissionTask?.cancel()
        audioEngine.stop()
        if tapInstalled { audioEngine.inputNode.removeTap(onBus: 0) }
        recognitionTask?.cancel()
    }

    public func setLocaleIdentifier(_ value: String) {
        guard Self.supportedLocaleIdentifiers.contains(value), !state.isBusy else { return }
        localeIdentifier = value
        rebuildRecognizer()
    }

    public static func stopAll() {
        registry = registry.filter { $0.value.value != nil }
        for box in registry.values { box.value?.stop() }
    }

    /// Starts recording only after an explicit user action. If the selected
    /// recognizer does not support on-device recognition, the request is
    /// rejected rather than silently sending audio to a remote service.
    public func start(appendingTo existingText: String = "") {
        guard !state.isBusy else { return }
        generation &+= 1
        let token = generation
        state = .requestingPermission
        permissionTask?.cancel()
        permissionTask = Task { [weak self] in
            await self?.begin(existingText: existingText, token: token)
        }
    }

    public func stop() {
        let wasBusy = state.isBusy
        generation &+= 1
        permissionTask?.cancel()
        permissionTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        guard wasBusy else { return }
        finishAudio()
        state = .stopped
        statusMessage = "听写已停止；文字仍在输入框中。"
    }

    public func clearError() { errorMessage = nil }

    private func begin(existingText: String, token: UInt64) async {
        guard token == generation, !Task.isCancelled, state == .requestingPermission else { return }
        errorMessage = nil
        state = .requestingPermission
        statusMessage = "等待麦克风和听写权限…"

        let speechAuthorized = await requestSpeechAuthorization()
        guard token == generation, state == .requestingPermission else { return }
        guard speechAuthorized else {
            fail("系统未允许听写。可在系统设置中允许 AgentDesk 使用语音识别。")
            return
        }
        let microphoneAuthorized = await requestMicrophoneAuthorization()
        guard token == generation, state == .requestingPermission else { return }
        guard microphoneAuthorized else {
            fail("系统未允许麦克风。可在系统设置中允许 AgentDesk 使用麦克风。")
            return
        }
        guard let recognizer, recognizer.isAvailable else {
            fail("当前语言的听写服务不可用。可以改用 macOS 系统听写。")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            fail("当前语言不支持本机听写；为避免把音频静默上传，AgentDesk 没有启动远程听写。可以改用 macOS 系统听写。")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        recognitionRequest = request
        baseText = existingText
        transcript = ""

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 && format.channelCount > 0 else {
            fail("没有可用的麦克风输入格式。")
            return
        }

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.state == .recording else { return }
                if let result {
                    self.transcriptGeneration = token
                    self.transcript = result.bestTranscription.formattedString
                    self.statusMessage = result.isFinal ? "听写已完成；文字仍在输入框中。" : "正在听…"
                    if result.isFinal { self.finishAudio(); self.state = .stopped }
                }
                if let error, !Task.isCancelled {
                    self.fail("听写失败：\(error.localizedDescription)")
                }
            }
        }

        if tapInstalled { inputNode.removeTap(onBus: 0); tapInstalled = false }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        tapInstalled = true
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            fail("无法启动麦克风：\(error.localizedDescription)")
            return
        }
        state = .recording
        permissionTask = nil
        statusMessage = "正在听（最多 60 秒）…"
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: (self?.maximumSeconds ?? 60) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.state == .recording else { return }
                self.stop()
                self.statusMessage = "已达到 60 秒上限。"
            }
        }
    }

    private func rebuildRecognizer() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    private func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private func fail(_ message: String) {
        generation &+= 1
        permissionTask?.cancel()
        permissionTask = nil
        timeoutTask?.cancel()
        finishAudio()
        state = .failed
        errorMessage = message
        statusMessage = message
    }

    private func finishAudio() {
        audioEngine.stop()
        if tapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private final class WeakBox {
        weak var value: SpeechRecognitionController?
        init(_ value: SpeechRecognitionController) { self.value = value }
    }
    private static var registry: [ObjectIdentifier: WeakBox] = [:]
    private static func register(_ value: SpeechRecognitionController) {
        registry[ObjectIdentifier(value)] = WeakBox(value)
    }
}

/// A small composer control. Recognized text is copied into the binding but
/// is never sent automatically; the user still presses Send.
public struct DictationButton: View {
    @Binding private var text: String
    @StateObject private var controller: SpeechRecognitionController
    @State private var lastTranscript = ""

    public init(text: Binding<String>, localeIdentifier: String = Locale.current.identifier) {
        _text = text
        _controller = StateObject(wrappedValue: SpeechRecognitionController(localeIdentifier: localeIdentifier))
    }

    public init(text: Binding<String>, controller: SpeechRecognitionController) {
        _text = text
        _controller = StateObject(wrappedValue: controller)
    }

    public init(text: Binding<String>, controller: SpeechRecognitionController, isEnabled: Bool) {
        _text = text
        _controller = StateObject(wrappedValue: controller)
        self.isEnabled = isEnabled
    }

    private var isEnabled = true

    public var body: some View {
        Button {
            if controller.state.isBusy { controller.stop() }
            else {
                lastTranscript = ""
                controller.start(appendingTo: text)
            }
        } label: {
            Label(controller.state.isBusy ? "停止听写" : "听写", systemImage: controller.state.isBusy ? "stop.circle.fill" : "mic.fill")
        }
        .disabled(!isEnabled)
        .buttonStyle(.bordered)
        .tint(controller.state.isRecording ? .orange : .accentColor)
        .help(controller.state.isRecording ? "停止听写" : "开始本机听写")
        .onChange(of: controller.transcript) { _, value in
            // Partial recognition results replace the previous partial result;
            // replace that suffix instead of appending every intermediate one.
            guard isEnabled, controller.transcriptIsCurrent, !value.isEmpty else { return }
            if !lastTranscript.isEmpty, text.hasSuffix(lastTranscript) {
                text = String(text.dropLast(lastTranscript.count)) + value
            } else if text.isEmpty {
                text = value
            } else {
                text += (text.hasSuffix(" ") || text.hasSuffix("\n") ? "" : " ") + value
            }
            lastTranscript = value
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { controller.stop() }
        }
        .onDisappear { controller.stop() }
        .alert("听写未完成", isPresented: Binding(get: { controller.errorMessage != nil }, set: { if !$0 { controller.clearError() } })) {
            Button("好") { controller.clearError() }
        } message: {
            Text(controller.errorMessage ?? "")
        }
    }
}

public struct SpeechLocalePicker: View {
    @ObservedObject private var controller: SpeechRecognitionController
    public init(controller: SpeechRecognitionController) { self.controller = controller }
    public var body: some View {
        Picker("听写语言", selection: Binding(get: { controller.localeIdentifier }, set: { controller.setLocaleIdentifier($0) })) {
            Text("中文（简体）").tag("zh-CN")
            Text("English（UK）").tag("en-GB")
            Text("English（US）").tag("en-US")
        }
        .disabled(controller.state.isBusy)
    }
}
