// Koe: 右⌘を押している間だけ聞き取り、離すと前面のアプリに文字を貼る。
// 認識は macOS 26 以降の SpeechTranscriber（Macの中で処理）。
import Cocoa
import AVFoundation
import Speech

let rightCmdKey: UInt16 = 54
let rightCmdMask: UInt = 0x10          // NX_DEVICERCMDKEYMASK
let minHold = 0.4                      // これより短い押下は無視
let tail = 0.25                        // 離してから少し録り続ける
let ownEventMark: Int64 = 0x4B4F45     // 自分が送ったキーイベントの印
let logDir = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Koe")
let logURL = logDir.appendingPathComponent("koe.log")

// 記録するのは時刻・押していた時間・待ち時間・文字数・前面アプリだけ（話した内容は残さない）
func log(_ s: String) {
  try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
  let line = "\(ISO8601DateFormatter().string(from: Date())) \(s)\n"
  if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
  else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
}

// 画面下の吹き出し。確定した文字は白、途中の文字は灰色
final class Bubble {
  let panel: NSPanel
  let label = NSTextField(wrappingLabelWithString: "")
  init() {
    panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 60),
                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.ignoresMouseEvents = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let bg = NSVisualEffectView()
    bg.material = .hudWindow; bg.state = .active; bg.wantsLayer = true
    bg.layer?.cornerRadius = 14; bg.layer?.masksToBounds = true
    panel.contentView = bg
    label.font = .systemFont(ofSize: 17)
    label.translatesAutoresizingMaskIntoConstraints = false
    bg.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 16),
      label.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -16),
      label.topAnchor.constraint(equalTo: bg.topAnchor, constant: 12),
      label.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -12),
    ])
  }
  func show() { update(done: "", pending: "🎙 聞いています…"); panel.orderFrontRegardless() }
  func hide() { panel.orderOut(nil) }
  func update(done: String, pending: String) {
    // 長くなったら末尾だけ見せる
    var d = done
    if d.count + pending.count > 140 { d = "…" + String(d.suffix(max(0, 140 - pending.count))) }
    let a = NSMutableAttributedString(string: d, attributes: [.foregroundColor: NSColor.labelColor])
    a.append(NSAttributedString(string: pending, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
    label.attributedStringValue = a
    guard let screen = NSScreen.main else { return }
    let w: CGFloat = 640
    let h = label.sizeThatFits(NSSize(width: w - 32, height: 400)).height + 24
    let f = screen.visibleFrame
    panel.setFrame(NSRect(x: f.midX - w / 2, y: f.minY + 80, width: w, height: max(h, 44)), display: true)
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  var statusItem: NSStatusItem!
  let engine = AVAudioEngine()
  var targetFormat: AVAudioFormat?
  var converter: AVAudioConverter?
  var recording = false
  var cancelled = false
  var downAt = Date()
  var cont: AsyncStream<AnalyzerInput>.Continuation?
  var analyzer: SpeechAnalyzer?
  var startTask: Task<Void, Error>?
  var resultsTask: Task<String, Error>?
  var savedClipboard: String?
  var pastedAny = false
  var lastWasCJK = false
  let bubble = Bubble()
  var demoFile: String?

  func applicationDidFinishLaunching(_ n: Notification) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    setIcon(active: false)
    let menu = NSMenu()
    menu.addItem(withTitle: "右⌘を押している間だけ聞き取ります", action: nil, keyEquivalent: "")
    menu.addItem(.separator())
    menu.addItem(withTitle: "Koeを終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    statusItem.menu = menu

    let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    log("start accessibility=\(AXIsProcessTrustedWithOptions(opts))")
    AVCaptureDevice.requestAccess(for: .audio) { ok in log("mic=\(ok)") }

    NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] e in self?.onFlags(e) }
    NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
      if e.cgEvent?.getIntegerValueField(.eventSourceUserData) == ownEventMark { return }
      // 右⌘を押したまま他のキー＝ショートカットなので取り消す
      if self?.recording == true { self?.cancelled = true; self?.stop() }
    }
    // 開発用: `defaults write org.arasaki.koe EnableDemo -bool true` のときだけ koe-demo を受け付ける
    if UserDefaults.standard.bool(forKey: "EnableDemo") {
    DistributedNotificationCenter.default().addObserver(forName: Notification.Name("org.arasaki.koe.demo"), object: nil, queue: .main) { [weak self] n in
      guard let self, let path = n.object as? String else { return }
      log("demo \(path)")
      self.demoFile = path
      self.start()
    }
    }
    Task { @MainActor in
      let t = SpeechTranscriber(locale: Locale(identifier: "ja-JP"), preset: .transcription)
      if let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) { try? await req.downloadAndInstall() }
      targetFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])
      log("ready format=\(targetFormat.map { "\($0)" } ?? "nil")")
    }
  }

  func setIcon(active: Bool) {
    let img = NSImage(systemSymbolName: active ? "mic.fill" : "mic", accessibilityDescription: "Koe")
    statusItem.button?.image = img
    statusItem.button?.contentTintColor = active ? .systemRed : nil
  }

  func onFlags(_ e: NSEvent) {
    guard e.keyCode == rightCmdKey else { return }
    let down = e.modifierFlags.rawValue & rightCmdMask != 0
    if down && !recording { start() }
    else if !down && recording {
      DispatchQueue.main.asyncAfter(deadline: .now() + tail) { [weak self] in
        if self?.recording == true { self?.stop() }
      }
    }
  }

  func start() {
    guard let target = targetFormat else { NSSound.beep(); return }
    recording = true; cancelled = false; downAt = Date()
    pastedAny = false; lastWasCJK = false
    savedClipboard = NSPasteboard.general.string(forType: .string)
    setIcon(active: true)
    bubble.show()

    let transcriber = SpeechTranscriber(locale: Locale(identifier: "ja-JP"), preset: .progressiveTranscription)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    self.analyzer = analyzer
    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    self.cont = cont
    resultsTask = Task { @MainActor in
      var done = ""
      for try await r in transcriber.results {
        let t = String(r.text.characters)
        if r.isFinal {
          let chunk = self.joinChunk(Self.tidy(t))
          done += chunk
          if !self.cancelled && !chunk.isEmpty { self.paste(chunk) }
          self.bubble.update(done: done, pending: "")
        } else {
          self.bubble.update(done: done, pending: Self.tidy(t))
        }
      }
      return done
    }
    startTask = Task { try await analyzer.start(inputSequence: stream) }

    if let path = demoFile {
      demoFile = nil
      downAt = Date().addingTimeInterval(-10)
      if let f = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) {
        converter = AVAudioConverter(from: f.processingFormat, to: target)
        while f.framePosition < f.length {
          let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4096)!
          try? f.read(into: b); feed(b, target)
        }
      }
      stop(); return
    }
    let input = engine.inputNode
    let inFmt = input.outputFormat(forBus: 0)
    converter = AVAudioConverter(from: inFmt, to: target)
    input.installTap(onBus: 0, bufferSize: 4096, format: inFmt) { [weak self] buf, _ in self?.feed(buf, target) }
    do { try engine.start() } catch { log("engine error \(error)"); stop() }
  }

  func feed(_ buf: AVAudioPCMBuffer, _ target: AVAudioFormat) {
    guard let converter else { return }
    let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
    var given = false
    var err: NSError?
    converter.convert(to: out, error: &err) { _, status in
      if given { status.pointee = .noDataNow; return nil }
      given = true; status.pointee = .haveData; return buf
    }
    if out.frameLength > 0 { cont?.yield(AnalyzerInput(buffer: out)) }
  }

  func stop() {
    guard recording else { return }
    recording = false
    if engine.isRunning { engine.inputNode.removeTap(onBus: 0); engine.stop() }
    setIcon(active: false)
    cont?.finish()
    let held = Date().timeIntervalSince(downAt) - tail
    let cancel = cancelled || held < minHold
    guard let analyzer, let startTask, let resultsTask else { return }
    let releasedAt = Date()
    Task { @MainActor in
      if cancel && !pastedAny { await analyzer.cancelAndFinishNow(); self.bubble.hide(); self.restoreClipboard(); return }
      _ = try? await startTask.value
      try? await analyzer.finalizeAndFinishThroughEndOfInput()
      let text = (try? await resultsTask.value) ?? ""
      log(String(format: "held=%.1fs wait=%.2fs chars=%d", held, Date().timeIntervalSince(releasedAt), text.count))
      if text.isEmpty { NSSound.beep() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.bubble.hide() }
      self.restoreClipboard()
    }
  }

  // 日本語の間に入る半角スペース（「世界で 7番目」）を取る
  static func tidy(_ s: String) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.replacingOccurrences(of: " (?=[^\\x00-\\x7F])|(?<=[^\\x00-\\x7F]) ", with: "", options: .regularExpression)
  }

  // かたまりの境目：英数字どうしの間だけ半角スペースを残す
  func joinChunk(_ t: String) -> String {
    guard let first = t.unicodeScalars.first else { return t }
    let firstASCII = first.isASCII
    let out = (pastedAny && !lastWasCJK && firstASCII) ? " " + t : t
    if let last = t.unicodeScalars.last { lastWasCJK = !last.isASCII }
    return out
  }

  func paste(_ text: String) {
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
    log("paste chars=\(text.count) front=\(front) trusted=\(AXIsProcessTrusted()) cancelled=\(cancelled) recording=\(recording)")
    pastedAny = true
    let pb = NSPasteboard.general
    pb.clearContents(); pb.setString(text, forType: .string)
    let src = CGEventSource(stateID: .combinedSessionState)
    for keyDown in [true, false] {
      let e = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: keyDown)  // V
      e?.flags = .maskCommand
      e?.setIntegerValueField(.eventSourceUserData, value: ownEventMark)
      e?.post(tap: .cghidEventTap)
    }
  }

  func restoreClipboard() {
    let old = savedClipboard
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
      if let old { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(old, forType: .string) }
    }
  }
}

// 自己テスト: Koe --selftest 音声.wav （マイクの代わりにファイルを4096フレームずつ流す）
if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
  let path = CommandLine.arguments[i + 1]
  let d = AppDelegate()
  let sem = DispatchSemaphore(value: 0)
  Task {
    let t = SpeechTranscriber(locale: Locale(identifier: "ja-JP"), preset: .transcription)
    let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t])!
    let analyzer = SpeechAnalyzer(modules: [t])
    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    d.cont = cont
    let results = Task { var s = ""; for try await r in t.results where r.isFinal { s += String(r.text.characters) }; return s }
    let st = Task { try await analyzer.start(inputSequence: stream) }
    let f = try! AVAudioFile(forReading: URL(fileURLWithPath: path))
    d.converter = AVAudioConverter(from: f.processingFormat, to: target)
    while f.framePosition < f.length {
      let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 4096)!
      try! f.read(into: b); d.feed(b, target)
    }
    cont.finish()
    let t0 = Date()
    _ = try? await st.value
    try? await analyzer.finalizeAndFinishThroughEndOfInput()
    let text = AppDelegate.tidy((try? await results.value) ?? "")
    print(String(format: "wait=%.2fs", Date().timeIntervalSince(t0)))
    print(text)
    sem.signal()
  }
  sem.wait(); exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
