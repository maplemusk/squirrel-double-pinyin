//
//  SquirrelInputController.swift
//  Squirrel
//
//  Created by Leo Liu on 5/7/24.
//

import InputMethodKit

final class SquirrelInputController: IMKInputController {
  private static let keyRollOver = 50
  private static var unknownAppCnt: UInt = 0

  private weak var client: IMKTextInput?
  private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var lastModifiers: NSEvent.ModifierFlags = .init()
  private var session: RimeSessionId = 0
  private(set) var schemaId: String = ""
  // ✅ 添加状态缓存
  private var lastNotifiedSchemaId: String = ""
  
  // ✅ 新增：全局缓存（类属性，所有实例共享）
  private static var cachedInlinePreedit: Bool?
  private static var cachedInlineCandidate: Bool?
  
  // ✅ 新增：缓存是否已初始化
  private static var isCacheInitialized = false
  
  private var inlinePreedit = false
  private var inlineCandidate = false
  // for chord-typing
  private var chordKeyCodes: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordModifiers: [UInt32] = .init(repeating: 0, count: SquirrelInputController.keyRollOver)
  private var chordKeyCount: Int = 0
  private var chordTimer: Timer?
  private var chordDuration: TimeInterval = 0
  private var currentApp: String = ""

  // swiftlint:disable:next cyclomatic_complexity
  override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
    guard let event = event else { return false }
    let modifiers = event.modifierFlags
    let changes = lastModifiers.symmetricDifference(modifiers)

    // Return true to indicate the the key input was received and dealt with.
    // Key processing will not continue in that case.  In other words the
    // system will not deliver a key down event to the application.
    // Returning false means the original key down will be passed on to the client.
    var handled = false

    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
      if session == 0 {
        return false
      }
    }

    self.client ?= sender as? IMKTextInput
    if let app = client?.bundleIdentifier(), currentApp != app {
      currentApp = app
      updateAppOptions()

        // ✅ 立即应用缓存（避免闪烁）
        loadConfigFromCache()
        
        // ✅ 异步加载精确配置
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.session != 0 else { return }
            
            var status = RimeStatus_stdbool.rimeStructInit()
            if self.rimeAPI.get_status(self.session, &status) {
                if let schema_id = status.schema_id {
                    let currentSchemaId = String(cString: schema_id)
                    if !currentSchemaId.isEmpty {
                        NSApp.squirrelAppDelegate.loadSettings(for: currentSchemaId)
                        self.schemaId = currentSchemaId
                        
                        if let panel = NSApp.squirrelAppDelegate.panel {
                            self.inlinePreedit = (panel.inlinePreedit && !self.rimeAPI.get_option(self.session, "no_inline"))
                                                || self.rimeAPI.get_option(self.session, "inline")
                            self.inlineCandidate = panel.inlineCandidate && !self.rimeAPI.get_option(self.session, "no_inline")
                            self.rimeAPI.set_option(self.session, "soft_cursor", !self.inlinePreedit)
                            
                            // ✅ 更新缓存
                            self.updateCache()
                        }
                    }
                }
                _ = self.rimeAPI.free_status(&status)
            }
        }
    }

    switch event.type {
    case .flagsChanged:
      if lastModifiers == modifiers {
        handled = true
        break
      }
      // print("[DEBUG] FLAGSCHANGED client: \(sender ?? "nil"), modifiers: \(modifiers)")
      var rimeModifiers: UInt32 = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
      // For flags-changed event, keyCode is available since macOS 10.15
      // (#715)
      let rimeKeycode: UInt32 = SquirrelKeycode.osxKeycodeToRime(keycode: event.keyCode, keychar: nil, shift: false, caps: false)

      if changes.contains(.capsLock) {
        // NOTE: rime assumes XK_Caps_Lock to be sent before modifier changes,
        // while NSFlagsChanged event has the flag changed already.
        // so it is necessary to revert kLockMask.
        rimeModifiers ^= kLockMask.rawValue
        _ = processKey(rimeKeycode, modifiers: rimeModifiers)
      }

      // Need to process release before modifier down. Because
      // sometimes release event is delayed to next modifier keydown.
      var buffer = [(keycode: UInt32, modifier: UInt32)]()
      for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] where changes.contains(flag) {
        if modifiers.contains(flag) { // New modifier
          buffer.append((keycode: rimeKeycode, modifier: rimeModifiers))
        } else { // Release
          buffer.insert((keycode: rimeKeycode, modifier: rimeModifiers | kReleaseMask.rawValue), at: 0)
        }
      }
      for (keycode, modifier) in buffer {
        _ = processKey(keycode, modifiers: modifier)
      }

      lastModifiers = modifiers
      rimeUpdate()

    case .keyDown:
      // ignore Command+X hotkeys.
      if modifiers.contains(.command) {
        break
      }

      let keyCode = event.keyCode
      var keyChars = event.charactersIgnoringModifiers
      let capitalModifiers = modifiers.isSubset(of: [.shift, .capsLock])
      if let code = keyChars?.first,
         (capitalModifiers && !code.isLetter) || (!capitalModifiers && !code.isASCII) {
        keyChars = event.characters
      }
      // print("[DEBUG] KEYDOWN client: \(sender ?? "nil"), modifiers: \(modifiers), keyCode: \(keyCode), keyChars: [\(keyChars ?? "empty")]")

      // translate osx keyevents to rime keyevents
      if let char = keyChars?.first {
        let rimeKeycode = SquirrelKeycode.osxKeycodeToRime(keycode: keyCode, keychar: char,
                                                           shift: modifiers.contains(.shift),
                                                           caps: modifiers.contains(.capsLock))
        if rimeKeycode != 0 {
          let rimeModifiers = SquirrelKeycode.osxModifiersToRime(modifiers: modifiers)
          handled = processKey(rimeKeycode, modifiers: rimeModifiers)
          rimeUpdate()
        }
      }

    default:
      break
    }

    return handled
  }

  func selectCandidate(_ index: Int) -> Bool {
    let success = rimeAPI.select_candidate_on_current_page(session, index)
    if success {
      rimeUpdate()
    }
    return success
  }

  // swiftlint:disable:next identifier_name
  func page(up: Bool) -> Bool {
    var handled = false
    handled = rimeAPI.change_page(session, up)
    if handled {
      rimeUpdate()
    }
    return handled
  }

  func moveCaret(forward: Bool) -> Bool {
    let currentCaretPos = rimeAPI.get_caret_pos(session)
    guard let input = rimeAPI.get_input(session) else { return false }
    if forward {
      if currentCaretPos <= 0 {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos - 1)
    } else {
      let inputStr = String(cString: input)
      if currentCaretPos >= inputStr.utf8.count {
        return false
      }
      rimeAPI.set_caret_pos(session, currentCaretPos + 1)
    }
    rimeUpdate()
    return true
  }

  override func recognizedEvents(_ sender: Any!) -> Int {
    // print("[DEBUG] recognizedEvents:")
    return Int(NSEvent.EventTypeMask.Element(arrayLiteral: .keyDown, .flagsChanged).rawValue)
  }

  override func activateServer(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] activateServer:")
    var keyboardLayout = NSApp.squirrelAppDelegate.config?.getString("keyboard_layout") ?? ""
    if keyboardLayout == "last" || keyboardLayout == "" {
      keyboardLayout = ""
    } else if keyboardLayout == "default" {
      keyboardLayout = "com.apple.keylayout.ABC"
    } else if !keyboardLayout.hasPrefix("com.apple.keylayout.") {
      keyboardLayout = "com.apple.keylayout.\(keyboardLayout)"
    }
    if keyboardLayout != "" {
      client?.overrideKeyboard(withKeyboardNamed: keyboardLayout)
    }
    preedit = ""
    
    // ✅ 2. 确保 session 存在
    if session == 0 || !rimeAPI.find_session(session) {
      createSession()
    }
    
    // ✅ 3. 立即从缓存加载配置（关键！）
    loadConfigFromCache()
    
    // ✅ 4. 异步预加载精确配置（不阻塞）
    if session != 0 {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            var status = RimeStatus_stdbool.rimeStructInit()
            if self.rimeAPI.get_status(self.session, &status) {
                if let schema_id = status.schema_id {
                    let currentSchemaId = String(cString: schema_id)
                    if !currentSchemaId.isEmpty {
                        // 只在 schema 变化时重新加载
                        if self.schemaId != currentSchemaId {
                            self.schemaId = currentSchemaId
                            NSApp.squirrelAppDelegate.loadSettings(for: self.schemaId)
                            
                            // 重新读取配置
                            if let panel = NSApp.squirrelAppDelegate.panel {
                                self.inlinePreedit = (panel.inlinePreedit && !self.rimeAPI.get_option(self.session, "no_inline"))
                                                    || self.rimeAPI.get_option(self.session, "inline")
                                self.inlineCandidate = panel.inlineCandidate && !self.rimeAPI.get_option(self.session, "no_inline")
                                self.rimeAPI.set_option(self.session, "soft_cursor", !self.inlinePreedit)
                                
                                // ✅ 更新缓存
                                self.updateCache()
                            }
                        }
                    }
                }
                _ = self.rimeAPI.free_status(&status)
            }
        }
    }
    // ✅ 5.预加载五笔码表（异步，不阻塞）
    DispatchQueue.global(qos: .utility).async {
        WubiCodeManager.shared.loadIfNeeded()
    }
    
    // ✅ 6. 异步状态同步（延迟执行，确保配置已加载）轻量级状态同步（<1ms）
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        self?.syncCurrentState()
    }
    
  }

  // ✅ 新增：主动同步当前状态
  private func syncCurrentState() {
    guard session != 0 else {
      // Session 未初始化，发送失活通知
      NotificationCenter.default.post(
        name: .squirrelInputMethodDeactivated,
        object: nil
      )
      return
    }
    
    var status = RimeStatus_stdbool.rimeStructInit()
    defer { _ = rimeAPI.free_status(&status) }
    
    guard rimeAPI.get_status(session, &status) else {
      // 状态读取失败，发送失活通知
      NotificationCenter.default.post(
        name: .squirrelInputMethodDeactivated,
        object: nil
      )
      return
    }
    
    // ✅ 只读取 schema_id
    if let schema_id = status.schema_id {
      schemaId = String(cString: schema_id)
    }
    
    // ✅ 发送激活通知
    NotificationCenter.default.post(
      name: .squirrelInputMethodActivated,
      object: nil
    )
    
    // ✅ 发送状态通知（菜单栏立即更新）
    postStatusNotification(schemaId: schemaId)
  }
  
  // ✅ 新增：从缓存加载配置
  private func loadConfigFromCache() {
      guard let panel = NSApp.squirrelAppDelegate.panel else { return }
      
      // 如果有缓存，直接使用
      if let cachedInline = Self.cachedInlinePreedit,
         let cachedCandidate = Self.cachedInlineCandidate {
          
          inlinePreedit = cachedInline
          inlineCandidate = cachedCandidate
          
          if session != 0 {
              rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
          }
          
          NSLog("📦 [Cache] Applied cached config: inlinePreedit=\(cachedInline), inlineCandidate=\(cachedCandidate)")
      } else {
          // 没有缓存，使用默认值
          inlinePreedit = panel.inlinePreedit
          inlineCandidate = panel.inlineCandidate
          
          if session != 0 {
              rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)
          }
          
          NSLog("📦 [Cache] No cache, using defaults: inlinePreedit=\(inlinePreedit), inlineCandidate=\(inlineCandidate)")
      }
  }
  
  // ✅ 新增：更新缓存
  private func updateCache() {
      Self.cachedInlinePreedit = inlinePreedit
      Self.cachedInlineCandidate = inlineCandidate
      Self.isCacheInitialized = true
      
      NSLog("💾 [Cache] Updated: inlinePreedit=\(inlinePreedit), inlineCandidate=\(inlineCandidate)")
  }

  override init!(server: IMKServer!, delegate: Any!, client: Any!) {
    self.client = client as? IMKTextInput
    // print("[DEBUG] initWithServer: \(server ?? .init()) delegate: \(delegate ?? "nil") client:\(client ?? "nil")")
    super.init(server: server, delegate: delegate, client: client)
    createSession()
    
    // ✅ 监听菜单栏的切换命令
    observeMenuBarCommands()
  }

  // ✅ 监听菜单栏命令
  private func observeMenuBarCommands() {
      
      // 切换输入方案
      NotificationCenter.default.addObserver(
          self,
          selector: #selector(handleSwitchSchema(_:)),
          name: .squirrelSwitchSchema,
          object: nil
      )
  }
  
  @objc private func handleSwitchSchema(_ notification: Notification) {
      guard session != 0 else {
          NSLog("⚠️ Session 未初始化，无法切换方案")
          return
      }
      
      guard let userInfo = notification.userInfo,
            let schemaId = userInfo["schemaId"] as? String,
            !schemaId.isEmpty else {
          NSLog("⚠️ 无效的 schemaId")
          return
      }
      
      DispatchQueue.main.async { [weak self] in
          guard let self = self,
                self.session != 0,
                self.rimeAPI.find_session(self.session) else {
              NSLog("⚠️ Session 已失效")
              return
          }
          
          // ✅ 设置标志，禁用状态提示
          NSApp.squirrelAppDelegate.setSwitchingSchemaFromMenu(true)
          
          schemaId.withCString { cSchemaId in
              let success = self.rimeAPI.select_schema(self.session, cSchemaId)
              if success {
                  NSLog("✅ 方案切换成功: \(schemaId)")
                  self.schemaId = schemaId
                  
                // ✅ 移除了强制设置 ascii_mode 的代码
                // 保持用户当前的输入模式（中文/英文）
                
                NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
                  self.postStatusNotification()
                  self.rimeUpdate()
                  
                  // ✅ 延迟恢复标志（确保通知已处理完）
                  DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                      NSApp.squirrelAppDelegate.setSwitchingSchemaFromMenu(false)
                  }
              } else {
                  NSLog("❌ 方案切换失败: \(schemaId)")
                  NSApp.squirrelAppDelegate.setSwitchingSchemaFromMenu(false)
              }
          }
      }
  }
  
  override func deactivateServer(_ sender: Any!) {
    // ✅ 发送失活通知

    NotificationCenter.default.post(
        name: .squirrelInputMethodDeactivated,
        object: nil
    )
    /*
    DispatchQueue.main.async {
        NotificationCenter.default.post(
            name: .squirrelInputMethodDeactivated,
            object: nil
        )
    }
     */
    
    hidePalettes()
    commitComposition(sender)
    client = nil
  }

  override func hidePalettes() {
    NSApp.squirrelAppDelegate.panel?.hide()
    super.hidePalettes()
  }

  /*!
   @method
   @abstract   Called when a user action was taken that ends an input session.
   Typically triggered by the user selecting a new input method
   or keyboard layout.
   @discussion When this method is called your controller should send the
   current input buffer to the client via a call to
   insertText:replacementRange:.  Additionally, this is the time
   to clean up if that is necessary.
   */
  override func commitComposition(_ sender: Any!) {
    self.client ?= sender as? IMKTextInput
    // print("[DEBUG] commitComposition: \(sender ?? "nil")")
    //  commit raw input
    if session != 0 {
      if let input = rimeAPI.get_input(session) {
        commit(string: String(cString: input))
        rimeAPI.clear_composition(session)
      }
    }
  }

  override func menu() -> NSMenu! {
    let deploy = NSMenuItem(title: NSLocalizedString("Deploy", comment: "Menu item"), action: #selector(deploy), keyEquivalent: "`")
    deploy.target = self
    deploy.keyEquivalentModifierMask = [.control, .option]
    let sync = NSMenuItem(title: NSLocalizedString("Sync user data", comment: "Menu item"), action: #selector(syncUserData), keyEquivalent: "")
    sync.target = self
    let logDir = NSMenuItem(title: NSLocalizedString("Logs...", comment: "Menu item"), action: #selector(openLogFolder), keyEquivalent: "")
    logDir.target = self
    let setting = NSMenuItem(title: NSLocalizedString("Settings...", comment: "Menu item"), action: #selector(openRimeFolder), keyEquivalent: "")
    setting.target = self
    let wiki = NSMenuItem(title: NSLocalizedString("Rime Wiki...", comment: "Menu item"), action: #selector(openWiki), keyEquivalent: "")
    wiki.target = self
    let update = NSMenuItem(title: NSLocalizedString("Check for updates...", comment: "Menu item"), action: #selector(checkForUpdates), keyEquivalent: "")
    update.target = self

    let menu = NSMenu()
    menu.addItem(deploy)
    menu.addItem(sync)
    menu.addItem(logDir)
    menu.addItem(setting)
    menu.addItem(wiki)
    menu.addItem(update)

    return menu
  }

  @objc func deploy() {
    NSApp.squirrelAppDelegate.deploy()
  }

  @objc func syncUserData() {
    NSApp.squirrelAppDelegate.syncUserData()
  }

  @objc func openLogFolder() {
    NSApp.squirrelAppDelegate.openLogFolder()
  }

  @objc func openRimeFolder() {
    NSApp.squirrelAppDelegate.openRimeFolder()
  }

  @objc func checkForUpdates() {
    NSApp.squirrelAppDelegate.checkForUpdates()
  }

  @objc func openWiki() {
    NSApp.squirrelAppDelegate.openWiki()
  }

  deinit {
    destroySession()
  }
}

private extension SquirrelInputController {

  func onChordTimer(_: Timer) {
    // chord release triggered by timer
    var processedKeys = false
    if chordKeyCount > 0 && session != 0 {
      // simulate key-ups
      for i in 0..<chordKeyCount {
        let handled = rimeAPI.process_key(session, Int32(chordKeyCodes[i]), Int32(chordModifiers[i] | kReleaseMask.rawValue))
        if handled {
          processedKeys = true
        }
      }
    }
    clearChord()
    if processedKeys {
      rimeUpdate()
    }
  }

  func updateChord(keycode: UInt32, modifiers: UInt32) {
    // print("[DEBUG] update chord: {\(chordKeyCodes)} << \(keycode)")
    for i in 0..<chordKeyCount where chordKeyCodes[i] == keycode {
      return
    }
    if chordKeyCount >= Self.keyRollOver {
      // you are cheating. only one human typist (fingers <= 10) is supported.
      return
    }
    chordKeyCodes[chordKeyCount] = keycode
    chordModifiers[chordKeyCount] = modifiers
    chordKeyCount += 1
    // reset timer
    if let timer = chordTimer, timer.isValid {
      timer.invalidate()
    }
    chordDuration = 0.1
    if let duration = NSApp.squirrelAppDelegate.config?.getDouble("chord_duration"), duration > 0 {
      chordDuration = duration
    }
    chordTimer = Timer.scheduledTimer(withTimeInterval: chordDuration, repeats: false, block: onChordTimer)
  }

  func clearChord() {
    chordKeyCount = 0
    if let timer = chordTimer {
      if timer.isValid {
        timer.invalidate()
      }
      chordTimer = nil
    }
  }

  func createSession() {
    let app = client?.bundleIdentifier() ?? {
      SquirrelInputController.unknownAppCnt &+= 1
      return "UnknownApp\(SquirrelInputController.unknownAppCnt)"
    }()
    print("createSession: \(app)")
    currentApp = app
    session = rimeAPI.create_session()
    schemaId = ""

    if session != 0 {
      updateAppOptions()
    }
  }

  func updateAppOptions() {
    if currentApp == "" {
      return
    }
    if let appOptions = NSApp.squirrelAppDelegate.config?.getAppOptions(currentApp) {
      for (key, value) in appOptions {
        print("set app option: \(key) = \(value)")
        rimeAPI.set_option(session, key, value)
      }
    }
  }

  func destroySession() {
    // print("[DEBUG] destroySession:")
    if session != 0 {
      _ = rimeAPI.destroy_session(session)
      session = 0
    }
    clearChord()
  }

  func processKey(_ rimeKeycode: UInt32, modifiers rimeModifiers: UInt32) -> Bool {
    // TODO add special key event preprocessing here

    // with linear candidate list, arrow keys may behave differently.
    if let panel = NSApp.squirrelAppDelegate.panel {
      if panel.linear != rimeAPI.get_option(session, "_linear") {
        rimeAPI.set_option(session, "_linear", panel.linear)
      }
      // with vertical text, arrow keys may behave differently.
      if panel.vertical != rimeAPI.get_option(session, "_vertical") {
        rimeAPI.set_option(session, "_vertical", panel.vertical)
      }
    }

    let handled = rimeAPI.process_key(session, Int32(rimeKeycode), Int32(rimeModifiers))
    // print("[DEBUG] rime_keycode: \(rimeKeycode), rime_modifiers: \(rimeModifiers), handled = \(handled)")

    // TODO add special key event postprocessing here

    if !handled {
      let isVimBackInCommandMode = rimeKeycode == XK_Escape || ((rimeModifiers & kControlMask.rawValue != 0) && (rimeKeycode == XK_c || rimeKeycode == XK_C || rimeKeycode == XK_bracketleft))
      if isVimBackInCommandMode && rimeAPI.get_option(session, "vim_mode") &&
          !rimeAPI.get_option(session, "ascii_mode") {
        rimeAPI.set_option(session, "ascii_mode", true)
        // print("[DEBUG] turned Chinese mode off in vim-like editor's command mode")
      }
    } else {
      let isChordingKey = switch Int32(rimeKeycode) {
      case XK_space...XK_asciitilde, XK_Control_L, XK_Control_R, XK_Alt_L, XK_Alt_R, XK_Shift_L, XK_Shift_R:
        true
      default:
        false
      }
      if isChordingKey && rimeAPI.get_option(session, "_chord_typing") {
        updateChord(keycode: rimeKeycode, modifiers: rimeModifiers)
      } else if (rimeModifiers & kReleaseMask.rawValue) == 0 {
        // non-chording key pressed
        clearChord()
      }
    }

    return handled
  }

  func rimeConsumeCommittedText() {
    var commitText = RimeCommit.rimeStructInit()
    if rimeAPI.get_commit(session, &commitText) {
      if let text = commitText.text {
        commit(string: String(cString: text))
      }
      _ = rimeAPI.free_commit(&commitText)
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  func rimeUpdate() {
    // print("[DEBUG] rimeUpdate")
    rimeConsumeCommittedText()

    var status = RimeStatus_stdbool.rimeStructInit()
    
    if rimeAPI.get_status(session, &status) {
      // enable schema specific ui style
      // swiftlint:disable:next identifier_name
      if let schema_id = status.schema_id {
        let newSchemaId = String(cString: schema_id)
        
        // ✅ 首次初始化 OR schema 变化时加载配置
        if schemaId == "" || schemaId != newSchemaId {
          schemaId = newSchemaId
          
          // ✅ 在此处加载配置（用户已开始输入，延迟可接受）
          NSApp.squirrelAppDelegate.loadSettings(for: schemaId)
          
                // 2. 更新 inline 配置
                    if let panel = NSApp.squirrelAppDelegate.panel {
                    inlinePreedit = (panel.inlinePreedit && !rimeAPI.get_option(session, "no_inline"))
                                    || rimeAPI.get_option(session, "inline")
                    inlineCandidate = panel.inlineCandidate && !rimeAPI.get_option(session, "no_inline")
                    // if not inline, embed soft cursor in preedit string
                    rimeAPI.set_option(session, "soft_cursor", !inlinePreedit)

                    // ✅ 更新缓存（关键！）
                    updateCache()
                }
    
          // ✅ 发送状态通知（观察式）
          postStatusNotification()
        }
      }
      _ = rimeAPI.free_status(&status)
    }
    
    
    var ctx = RimeContext_stdbool.rimeStructInit()
    if rimeAPI.get_context(session, &ctx) {
      // update preedit text
      let preedit = ctx.composition.preedit.map({ String(cString: $0) }) ?? ""

      let start = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_start)), within: preedit) ?? preedit.startIndex
      let end = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.sel_end)), within: preedit) ?? preedit.startIndex
      let caretPos = String.Index(preedit.utf8.index(preedit.utf8.startIndex, offsetBy: Int(ctx.composition.cursor_pos)), within: preedit) ?? preedit.startIndex

      if inlineCandidate {
        var candidatePreview = ctx.commit_text_preview.map { String(cString: $0) } ?? ""
        let endOfCandidatePreview = candidatePreview.endIndex
        if inlinePreedit {
          // 左移光標後的情形：
          // preedit:             ^已選某些字[xiang zuo yi dong]|guangbiao$
          // commit_text_preview: ^已選某些字向左移動$
          // candidate_preview:   ^已選某些字[向左移動]|guangbiao$
          // 繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidong$
          // candidate_preview:   ^已選某些字[向左]yidong|guangbiao$
          // 光標移至當前段落最左端的情形：
          // preedit:             ^已選某些字|[xiang zuo yi dong guang biao]$
          // commit_text_preview: ^已選某些字向左移動光標$
          // candidate_preview:   ^已選某些字|[向左移動光標]$
          // 討論：
          // preedit 與 commit_text_preview 中“已選某些字”部分一致
          // 因此，選中範圍即正在翻譯的碼段“向左移動”中，兩者的 start 值一致
          // 光標位置的範圍是 start ..= endOfCandidatePreview
          if caretPos >= end && caretPos < preedit.endIndex {
            // 從 preedit 截取光標後未翻譯的編碼“guangbiao”
            candidatePreview += preedit[caretPos...]
          }
        } else {
          // 翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字[xiang zuo]yidong|guangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字[向左???]|$
          // 光標移至當前段落最左端，繼續翻頁至指定更短字詞的情形：
          // preedit:             ^已選某些字|[xiang zuo]yidongguangbiao$
          // commit_text_preview: ^已選某些字向左yidongguangbiao$
          // candidate_preview:   ^已選某些字|[向左]???$
          // FIXME: add librime APIs to support preview candidate without remaining code.
        }
        // preedit can contain additional prompt text before start:
        // ^(prompt)[selection]$
        let start = min(start, candidatePreview.endIndex)
        // caret can be either before or after the selected range.
        let caretPos = caretPos <= start ? caretPos : endOfCandidatePreview
        show(preedit: candidatePreview,
             selRange: NSRange(location: start.utf16Offset(in: candidatePreview),
                               length: candidatePreview.utf16.distance(from: start, to: candidatePreview.endIndex)),
             caretPos: caretPos.utf16Offset(in: candidatePreview))
      } else {
        if inlinePreedit {
          show(preedit: preedit, selRange: NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end)), caretPos: caretPos.utf16Offset(in: preedit))
        } else {
          // TRICKY: display a non-empty string to prevent iTerm2 from echoing
          // each character in preedit. note this is a full-shape space U+3000;
          // using half shape characters like "..." will result in an unstable
          // baseline when composing Chinese characters.
          show(preedit: preedit.isEmpty ? "" : "　", selRange: NSRange(location: 0, length: 0), caretPos: 0)
        }
      }

      // update candidates
      let numCandidates = Int(ctx.menu.num_candidates)
      var candidates = [String]()
      var comments = [String]()
      
      // ✅ 预加载五笔码表（如果是第一次）
      // WubiCodeManager.shared.loadIfNeeded()
      
      // ✅ 判断当前是否为双拼方案 (根据 schemaId 判断)
      let isDoublePinyin = self.schemaId.contains("double_pinyin")

      for i in 0..<numCandidates {
        let candidate = ctx.menu.candidates[i]
        let text = candidate.text.map { String(cString: $0) } ?? ""
        var comment = candidate.comment.map { String(cString: $0) } ?? ""
        
        // 🔥🔥🔥 核心修改开始 🔥🔥🔥
        if isDoublePinyin {
            // 需求：只匹配单字和2字
            if text.count >= 1 && text.count <= 2 {
                if let wubiCode = WubiCodeManager.shared.getCode(for: text) {
                    // 追加显示，格式可以自定义，例如：(aldj)
                    // 如果原有 comment 为空，直接显示；如果不为空，加个空格追加
                    if comment.isEmpty {
                        comment = "(\(wubiCode))"
                    } else {
                        comment += " (\(wubiCode))"
                    }
                }
            }
        }
        // 🔥🔥🔥 核心修改结束 🔥🔥🔥

        candidates.append(text)
        comments.append(comment)
      }

      var labels = [String]()
      // swiftlint:disable identifier_name
      if let select_keys = ctx.menu.select_keys {
        labels = String(cString: select_keys).map { String($0) }
      } else if let select_labels = ctx.select_labels {
        let pageSize = Int(ctx.menu.page_size)
        for i in 0..<pageSize {
          labels.append(select_labels[i].map { String(cString: $0) } ?? "")
        }
      }
      // swiftlint:enable identifier_name
      let page = Int(ctx.menu.page_no)
      let lastPage = ctx.menu.is_last_page

      let selRange = NSRange(location: start.utf16Offset(in: preedit), length: preedit.utf16.distance(from: start, to: end))
      showPanel(preedit: inlinePreedit ? "" : preedit, selRange: selRange, caretPos: caretPos.utf16Offset(in: preedit),
                candidates: candidates, comments: comments, labels: labels, highlighted: Int(ctx.menu.highlighted_candidate_index),
                page: page, lastPage: lastPage)
      _ = rimeAPI.free_context(&ctx)
    } else {
      hidePalettes()
    }
  }
  
  // ✅ 新增：带参数的版本（用于主动同步）
  private func postStatusNotification(schemaId: String) {
      guard session != 0 else { return }
      
      // 只在状态真正改变时发送通知
      if schemaId != lastNotifiedSchemaId {
          
          lastNotifiedSchemaId = schemaId
          
          NotificationCenter.default.post(
              name: .squirrelInputStateChanged,
              object: nil,
              userInfo: ["schemaId": schemaId]
          )
      }
  }
  
  // ✅ 优化后的状态通知方法
  // ✅ 保留原有版本（用于 rimeUpdate）
  private func postStatusNotification() {
      guard session != 0 else { return }

      postStatusNotification(schemaId: schemaId)
  }
  /*
  private func postStatusNotification() {
      guard session != 0 else { return }
      
      // 只在状态真正改变时发送通知
      if schemaId != lastNotifiedSchemaId {
          
          lastNotifiedSchemaId = schemaId
          
          NotificationCenter.default.post(
              name: .squirrelInputStateChanged,
              object: nil,
              userInfo: ["schemaId": schemaId]
          )
      }
  }
   */

  func commit(string: String) {
    guard let client = client else { return }
    // print("[DEBUG] commitString: \(string)")
    client.insertText(string, replacementRange: .empty)
    preedit = ""
    hidePalettes()
  }

  func show(preedit: String, selRange: NSRange, caretPos: Int) {
    guard let client = client else { return }
    // print("[DEBUG] showPreeditString: '\(preedit)'")
    if self.preedit == preedit && self.caretPos == caretPos && self.selRange == selRange {
      return
    }

    self.preedit = preedit
    self.caretPos = caretPos
    self.selRange = selRange

    // print("[DEBUG] selRange.location = \(selRange.location), selRange.length = \(selRange.length); caretPos = \(caretPos)")
    let start = selRange.location
    let attrString = NSMutableAttributedString(string: preedit)
    if start > 0 {
      let attrs = mark(forStyle: kTSMHiliteConvertedText, at: NSRange(location: 0, length: start))! as! [NSAttributedString.Key: Any]
      attrString.setAttributes(attrs, range: NSRange(location: 0, length: start))
    }
    let remainingRange = NSRange(location: start, length: preedit.utf16.count - start)
    let attrs = mark(forStyle: kTSMHiliteSelectedRawText, at: remainingRange)! as! [NSAttributedString.Key: Any]
    attrString.setAttributes(attrs, range: remainingRange)
    client.setMarkedText(attrString, selectionRange: NSRange(location: caretPos, length: 0), replacementRange: .empty)
  }

  // swiftlint:disable:next function_parameter_count
  func showPanel(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted: Int, page: Int, lastPage: Bool) {
    // print("[DEBUG] showPanelWithPreedit:...:")
    guard let client = client else { return }
    var inputPos = NSRect()
    client.attributes(forCharacterIndex: 0, lineHeightRectangle: &inputPos)
    if let panel = NSApp.squirrelAppDelegate.panel {
      panel.position = inputPos
      panel.inputController = self
      panel.update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels,
                   highlighted: highlighted, page: page, lastPage: lastPage, update: true)
    }
  }
}
