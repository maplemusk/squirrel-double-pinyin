//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//  Modified: 独立双拼提示窗 + 键盘UI + 智能双拼检测
//

import AppKit
import SwiftUI

// 迷你协议
protocol SchemaHintWindow {
    func configure(enabled: Bool)
    func updateScheme(from schemaId: String)
    func show(relativeTo candidateFrame: NSRect, onScreen screen: NSRect)
    func hide()
    func isConfigEnabled() -> Bool
}

// MARK: - SquirrelPanel (主面板)

final class SquirrelPanel: NSPanel {
  private let view: SquirrelView
  private let back: NSVisualEffectView
  private var currentSchemaId: String = ""  // ✅ 新增
  // ✅ 独立的悬浮窗口
  private var hintWindow: DoublePinyinHintWindow?
  private var wubiHintWindow: WubiHintWindow?
  private var schemaHintsEnabled: Bool = true

  weak var inputController: SquirrelInputController?  // ✅ 添加 weak

  var position: NSRect
  private var screenRect: NSRect = .zero
  private var maxHeight: CGFloat = 0

  private var statusMessage: String = ""
  private var statusTimer: Timer?

  private var preedit: String = ""
  private var selRange: NSRange = .empty
  private var caretPos: Int = 0
  private var candidates: [String] = .init()
  private var comments: [String] = .init()
  private var labels: [String] = .init()
  private var index: Int = 0
  private var cursorIndex: Int = 0
  private var scrollDirection: CGVector = .zero
  private var scrollTime: Date = .distantPast
  private var page: Int = 0
  private var lastPage: Bool = true
  private var pagingUp: Bool?

  init(position: NSRect) {
    self.position = position
    self.view = SquirrelView(frame: position)
    self.back = NSVisualEffectView()
    super.init(contentRect: position, styleMask: .nonactivatingPanel, backing: .buffered, defer: true)
    self.level = .init(Int(CGShieldingWindowLevel()))
    self.hasShadow = true
    self.isOpaque = false
    self.backgroundColor = .clear
    back.blendingMode = .behindWindow
    back.material = .hudWindow
    back.state = .active
    back.wantsLayer = true
    back.layer?.mask = view.shape
    let contentView = NSView()
    contentView.addSubview(back)
    contentView.addSubview(view)
    contentView.addSubview(view.textView)
    self.contentView = contentView
    
    // ✅ 初始化独立的悬浮窗口
    self.hintWindow = DoublePinyinHintWindow()
    
    self.wubiHintWindow = WubiHintWindow()
    
    NSLog("✅ [Squirrel] DoublePinyinHintWindow initialized")
  }

  var linear: Bool {
    view.currentTheme.linear
  }
  var vertical: Bool {
    view.currentTheme.vertical
  }
  var inlinePreedit: Bool {
    view.currentTheme.inlinePreedit
  }
  var inlineCandidate: Bool {
    view.currentTheme.inlineCandidate
  }

  // swiftlint:disable:next cyclomatic_complexity
  override func sendEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown:
      let (index, _, pagingUp) =  view.click(at: mousePosition())
      if let pagingUp {
        self.pagingUp = pagingUp
      } else {
        self.pagingUp = nil
      }
      if let index, index >= 0 && index < candidates.count {
        self.index = index
      }
    case .leftMouseUp:
      let (index, preeditIndex, pagingUp) = view.click(at: mousePosition())

      if let pagingUp, pagingUp == self.pagingUp {
        _ = inputController?.page(up: pagingUp)
      } else {
        self.pagingUp = nil
      }
      if let preeditIndex, preeditIndex >= 0 && preeditIndex < preedit.utf16.count {
        if preeditIndex < caretPos {
          _ = inputController?.moveCaret(forward: true)
        } else if preeditIndex > caretPos {
          _ = inputController?.moveCaret(forward: false)
        }
      }
      if let index, index == self.index && index >= 0 && index < candidates.count {
        _ = inputController?.selectCandidate(index)
      }
    case .mouseEntered:
      acceptsMouseMovedEvents = true
    case .mouseExited:
      acceptsMouseMovedEvents = false
      if cursorIndex != index {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
      pagingUp = nil
    case .mouseMoved:
      let (index, _, _) = view.click(at: mousePosition())
      if let index = index, cursorIndex != index && index >= 0 && index < candidates.count {
        update(preedit: preedit, selRange: selRange, caretPos: caretPos, candidates: candidates, comments: comments, labels: labels, highlighted: index, page: page, lastPage: lastPage, update: false)
      }
    case .scrollWheel:
      if event.phase == .began {
        scrollDirection = .zero
        // Scrollboard span
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
        // Mouse scroll wheel
      } else if event.phase == .init(rawValue: 0) && event.momentumPhase == .init(rawValue: 0) {
        if scrollTime.timeIntervalSinceNow < -1 {
          scrollDirection = .zero
        }
        scrollTime = .now
        if (scrollDirection.dy >= 0 && event.scrollingDeltaY > 0) || (scrollDirection.dy <= 0 && event.scrollingDeltaY < 0) {
          scrollDirection.dy += event.scrollingDeltaY
        } else {
          scrollDirection = .zero
        }
        if abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
          scrollDirection = .zero
        }
      } else {
        scrollDirection.dx += event.scrollingDeltaX
        scrollDirection.dy += event.scrollingDeltaY
      }
    default:
      break
    }
    super.sendEvent(event)
  }

  func hide() {
    statusTimer?.invalidate()
    statusTimer = nil
    orderOut(nil)
    maxHeight = 0
    
    // ✅ 隐藏悬浮窗口
    hintWindow?.hide()
    // ✅ 隐藏所有悬浮窗口（双拼 + 五笔）
    wubiHintWindow?.hide()  // 🔥 新增：同时隐藏五笔窗口
    
    // ✅ 清理 controller 引用（防止旧引用干扰）
    // ✅ 移除这行：weak 引用会自动管理生命周期
    // inputController = nil
  }

  // Main function to add attributes to text output from librime
  // swiftlint:disable:next cyclomatic_complexity function_parameter_count
  func update(preedit: String, selRange: NSRange, caretPos: Int, candidates: [String], comments: [String], labels: [String], highlighted index: Int, page: Int, lastPage: Bool, update: Bool) {
    if update {
      self.preedit = preedit
      self.selRange = selRange
      self.caretPos = caretPos
      self.candidates = candidates
      self.comments = comments
      self.labels = labels
      self.index = index
      self.page = page
      self.lastPage = lastPage
      
      // NSLog("📝 [Squirrel] update - candidates: \(candidates.count)")
      // ✅ 同步当前方案 ID 并自动更新键位布局
      /*
      if let schemaId = inputController?.schemaId, schemaId != currentSchemaId {
        currentSchemaId = schemaId
        hintWindow?.updateScheme(from: schemaId)  // 🔥 自动推断键位方案
        wubiHintWindow?.updateScheme(from: schemaId)  // ✅ 确保这行存在
      }
       */
      // ✅ 优化：直接从 inputController 读取最新的 schemaId
      // 不依赖 currentSchemaId 的比较（可能过时）
      if let controller = inputController, !controller.schemaId.isEmpty {
          let newSchemaId = controller.schemaId
          
          // 只在真正变化时更新悬浮窗
          if newSchemaId != currentSchemaId {
              currentSchemaId = newSchemaId
              hintWindow?.updateScheme(from: newSchemaId)
              wubiHintWindow?.updateScheme(from: newSchemaId)
          }
      }
    }
    cursorIndex = index

    if !candidates.isEmpty || !preedit.isEmpty {
      statusMessage = ""
      statusTimer?.invalidate()
      statusTimer = nil
    } else {
      if !statusMessage.isEmpty {
        show(status: statusMessage)
        statusMessage = ""
      } else if statusTimer == nil {
        hide()
      }
      return
    }

    let theme = view.currentTheme
    currentScreen()

    let text = NSMutableAttributedString()
    let preeditRange: NSRange
    let highlightedPreeditRange: NSRange

    // preedit
    if !preedit.isEmpty {
      preeditRange = NSRange(location: 0, length: preedit.utf16.count)
      highlightedPreeditRange = selRange

      let line = NSMutableAttributedString(string: preedit)
      line.addAttributes(theme.preeditAttrs, range: preeditRange)
      line.addAttributes(theme.preeditHighlightedAttrs, range: selRange)
      text.append(line)

      text.addAttribute(.paragraphStyle, value: theme.preeditParagraphStyle, range: NSRange(location: 0, length: text.length))
      if !candidates.isEmpty {
        text.append(NSAttributedString(string: "\n", attributes: theme.preeditAttrs))
      }
    } else {
      preeditRange = .empty
      highlightedPreeditRange = .empty
    }

    // candidates
    var candidateRanges = [NSRange]()
    for i in 0..<candidates.count {
      let attrs = i == index ? theme.highlightedAttrs : theme.attrs
      let labelAttrs = i == index ? theme.labelHighlightedAttrs : theme.labelAttrs
      let commentAttrs = i == index ? theme.commentHighlightedAttrs : theme.commentAttrs

      let label = if theme.candidateFormat.contains(/\[label\]/) {
        if labels.count > 1 && i < labels.count {
          labels[i]
        } else if labels.count == 1 && i < labels.first!.count {
          // custom: A. B. C...
          String(labels.first![labels.first!.index(labels.first!.startIndex, offsetBy: i)])
        } else {
          // default: 1. 2. 3...
          "\(i+1)"
        }
      } else {
        ""
      }

      let candidate = candidates[i].precomposedStringWithCanonicalMapping
      let comment = comments[i].precomposedStringWithCanonicalMapping

      let line = NSMutableAttributedString(string: theme.candidateFormat, attributes: labelAttrs)
      for range in line.string.ranges(of: /\[candidate\]/) {
        let convertedRange = convert(range: range, in: line.string)
        line.addAttributes(attrs, range: convertedRange)
        if candidate.count <= 5 {
          line.addAttribute(.noBreak, value: true, range: NSRange(location: convertedRange.location+1, length: convertedRange.length-1))
        }
      }
      for range in line.string.ranges(of: /\[comment\]/) {
        line.addAttributes(commentAttrs, range: convert(range: range, in: line.string))
      }
      line.mutableString.replaceOccurrences(of: "[label]", with: label, range: NSRange(location: 0, length: line.length))
      let labeledLine = line.copy() as! NSAttributedString
      line.mutableString.replaceOccurrences(of: "[candidate]", with: candidate, range: NSRange(location: 0, length: line.length))
      line.mutableString.replaceOccurrences(of: "[comment]", with: comment, range: NSRange(location: 0, length: line.length))

      if line.length <= 10 {
        line.addAttribute(.noBreak, value: true, range: NSRange(location: 1, length: line.length-1))
      }

      let lineSeparator = NSAttributedString(string: linear ? "  " : "\n", attributes: attrs)
      if i > 0 {
        text.append(lineSeparator)
      }
      let str = lineSeparator.mutableCopy() as! NSMutableAttributedString
      if vertical {
        str.addAttribute(.verticalGlyphForm, value: 1, range: NSRange(location: 0, length: str.length))
      }
      view.separatorWidth = str.boundingRect(with: .zero).width

      let paragraphStyleCandidate = (i == 0 ? theme.firstParagraphStyle : theme.paragraphStyle).mutableCopy() as! NSMutableParagraphStyle
      if linear {
        paragraphStyleCandidate.paragraphSpacingBefore -= theme.linespace
        paragraphStyleCandidate.lineSpacing = theme.linespace
      }
      if !linear, let labelEnd = labeledLine.string.firstMatch(of: /\[(candidate|comment)\]/)?.range.lowerBound {
        let labelString = labeledLine.attributedSubstring(from: NSRange(location: 0, length: labelEnd.utf16Offset(in: labeledLine.string)))
        let labelWidth = labelString.boundingRect(with: .zero, options: [.usesLineFragmentOrigin]).width
        paragraphStyleCandidate.headIndent = labelWidth
      }
      line.addAttribute(.paragraphStyle, value: paragraphStyleCandidate, range: NSRange(location: 0, length: line.length))

      candidateRanges.append(NSRange(location: text.length, length: line.length))
      text.append(line)
    }

    // text done!
    view.textView.textContentStorage?.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: candidateRanges, hilightedIndex: index, preeditRange: preeditRange, highlightedPreeditRange: highlightedPreeditRange, canPageUp: page > 0, canPageDown: !lastPage)
    show()
  }

  func updateStatus(long longMessage: String, short shortMessage: String) {
    let theme = view.currentTheme
    switch theme.statusMessageType {
    case .mix:
      statusMessage = shortMessage.isEmpty ? longMessage : shortMessage
    case .long:
      statusMessage = longMessage
    case .short:
      if !shortMessage.isEmpty {
        statusMessage = shortMessage
      } else if let initial = longMessage.first {
        statusMessage = String(initial)
      } else {
        statusMessage = ""
      }
    }
  }

  func load(config: SquirrelConfig, forDarkMode isDark: Bool) {
    if isDark {
      view.darkTheme = SquirrelTheme()
      view.darkTheme.load(config: config, dark: true)
    } else {
      view.lightTheme = SquirrelTheme()
      view.lightTheme.load(config: config, dark: isDark)
    }
    
    // ✅ 加载双拼提示配置
    loadDoublePinyinHintConfig(config: config)
  }
}

// MARK: - SquirrelPanel Private Extensions

private extension SquirrelPanel {
  
  // ✅ 核心逻辑：基于 schema_id 精准判断
  /*
  func updateDoublePinyinHint() { //升级整合到updateSchemaHints中
    // 1. 检查配置是否启用
    guard let hintWindow = hintWindow, hintWindow.isConfigEnabled() else {
      hintWindow?.hide()
      return
    }
    
    // 2. 检查是否有候选词
    guard !candidates.isEmpty else {
      hintWindow.hide()
      return
    }
    
    // 3. ✅ 基于 schema_id 精准判断是否为双拼方案
    // 根据配置文件，双拼方案的 schema_id 包含 "double_pinyin"
    let isDoublePinyin = currentSchemaId.contains("double_pinyin")
    
    if isDoublePinyin {
      // 显示时，基于当前 Panel 的位置
      hintWindow.show(relativeTo: self.frame, onScreen: screenRect)
    } else {
      hintWindow.hide()
    }
  }
   */
  
  // MARK: - 升级的整合updateSchemaHints
  func updateSchemaHints() {
      // ✅ 验证 inputController 仍然有效
      guard let controller = inputController,
            controller.schemaId == currentSchemaId else {
          hintWindow?.hide()
          wubiHintWindow?.hide()
          return
      }
    
      // 0️⃣ 总开关：一次性控制所有 Hint View
      guard schemaHintsEnabled else {
          hintWindow?.hide()
          wubiHintWindow?.hide()
          return
      }

      // 1️⃣ 必须有候选词（否则不显示任何 hint）
      guard !candidates.isEmpty else {
          hintWindow?.hide()
          wubiHintWindow?.hide()
          return
      }

      let schemaId = currentSchemaId

      let isDoublePinyin = schemaId.contains("double_pinyin")
      let isWubi = schemaId.contains("wubi")

      if isDoublePinyin {
          // 2️⃣ 双拼
          if hintWindow?.isConfigEnabled() == true {
              hintWindow?.show(relativeTo: self.frame, onScreen: screenRect)
          } else {
              hintWindow?.hide()
          }
          wubiHintWindow?.hide()

      } else if isWubi {
          // 3️⃣ 五笔
          if wubiHintWindow?.isConfigEnabled() == true {
              wubiHintWindow?.show(relativeTo: self.frame, onScreen: screenRect)
          } else {
              wubiHintWindow?.hide()
          }
          hintWindow?.hide()

      } else {
          // 4️⃣ 其他 schema
          hintWindow?.hide()
          wubiHintWindow?.hide()
      }
  }
  
  // ✅ 加载配置
  func loadDoublePinyinHintConfig(config: SquirrelConfig) {
    let enabled = config.getBool("double_pinyin_hints/enabled") ?? true
    
    NSLog("⚙️ [Squirrel] Schema hints enabled: \(enabled)")
    
    // ✅ 总开关
    schemaHintsEnabled = enabled
    
    // ✅ 同步给各个 Hint Window（可选，但推荐）
    hintWindow?.configure(enabled: enabled)
    
    wubiHintWindow?.configure(enabled: enabled)
    // 不再需要读取 scheme 配置！
  }

  
  func mousePosition() -> NSPoint {
    var point = NSEvent.mouseLocation
    point = self.convertPoint(fromScreen: point)
    return view.convert(point, from: nil)
  }

  func currentScreen() {
    if let screen = NSScreen.main {
      screenRect = screen.frame
    }
    for screen in NSScreen.screens where screen.frame.contains(position.origin) {
      screenRect = screen.frame
      break
    }
  }

  func maxTextWidth() -> CGFloat {
    let theme = view.currentTheme
    let font: NSFont = theme.font
    let fontScale = font.pointSize / 12
    let textWidthRatio = min(1, 1 / (vertical ? 4 : 3) + fontScale / 12)
    let maxWidth = if vertical {
      screenRect.height * textWidthRatio - theme.edgeInset.height * 2
    } else {
      screenRect.width * textWidthRatio - theme.edgeInset.width * 2
    }
    return maxWidth
  }

  // Get the window size, the windows will be the dirtyRect in
  // SquirrelView.drawRect
  // swiftlint:disable:next cyclomatic_complexity
  func show() {
    currentScreen()
    let theme = view.currentTheme
    if theme.native || view.darkTheme.available {
      self.appearance = NSApp.effectiveAppearance
    } else {
      // user configured only a light theme, set window appearance to light.
      self.appearance = NSAppearance(named: .aqua)
    }

    // Break line if the text is too long, based on screen size.
    let textWidth = maxTextWidth()
    let maxTextHeight = vertical ? screenRect.width - theme.edgeInset.width * 2 : screenRect.height - theme.edgeInset.height * 2
    view.textContainer.size = NSSize(width: textWidth, height: maxTextHeight)

    var panelRect = NSRect.zero
    // in vertical mode, the width and height are interchanged
    var contentRect = view.contentRect
    if theme.memorizeSize && (vertical && position.midY / screenRect.height < 0.5) ||
        (vertical && position.minX + max(contentRect.width, maxHeight) + theme.edgeInset.width * 2 > screenRect.maxX) {
      if contentRect.width >= maxHeight {
        maxHeight = contentRect.width
      } else {
        contentRect.size.width = maxHeight
        view.textContainer.size = NSSize(width: maxHeight, height: maxTextHeight)
      }
    }

    if vertical {
      panelRect.size = NSSize(width: min(0.95 * screenRect.width, contentRect.height + theme.edgeInset.height * 2),
                              height: min(0.95 * screenRect.height, contentRect.width + theme.edgeInset.width * 2) + theme.pagingOffset)

      // To avoid jumping up and down while typing, use the lower screen when
      // typing on upper, and vice versa
      if position.midY / screenRect.height >= 0.5 {
        panelRect.origin.y = position.minY - SquirrelTheme.offsetHeight - panelRect.height + theme.pagingOffset
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
      // Make the first candidate fixed at the left of cursor
      panelRect.origin.x = position.minX - panelRect.width - SquirrelTheme.offsetHeight
      if view.preeditRange.length > 0, let preeditTextRange = view.convert(range: view.preeditRange) {
        let preeditRect = view.contentRect(range: preeditTextRange)
        panelRect.origin.x += preeditRect.height + theme.edgeInset.width
      }
    } else {
      panelRect.size = NSSize(width: min(0.95 * screenRect.width, contentRect.width + theme.edgeInset.width * 2),
                              height: min(0.95 * screenRect.height, contentRect.height + theme.edgeInset.height * 2))
      panelRect.size.width += theme.pagingOffset
      panelRect.origin = NSPoint(x: position.minX - theme.pagingOffset, y: position.minY - SquirrelTheme.offsetHeight - panelRect.height)
    }
    if panelRect.maxX > screenRect.maxX {
      panelRect.origin.x = screenRect.maxX - panelRect.width
    }
    if panelRect.minX < screenRect.minX {
      panelRect.origin.x = screenRect.minX
    }
    if panelRect.minY < screenRect.minY {
      if vertical {
        panelRect.origin.y = screenRect.minY
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
    }
    if panelRect.maxY > screenRect.maxY {
      panelRect.origin.y = screenRect.maxY - panelRect.height
    }
    if panelRect.minY < screenRect.minY {
      panelRect.origin.y = screenRect.minY
    }
    self.setFrame(panelRect, display: true)

    // rotate the view, the core in vertical mode!
    if vertical {
      contentView!.boundsRotation = -90
      contentView!.setBoundsOrigin(NSPoint(x: 0, y: panelRect.width))
    } else {
      contentView!.boundsRotation = 0
      contentView!.setBoundsOrigin(.zero)
    }
    view.textView.boundsRotation = 0
    view.textView.setBoundsOrigin(.zero)

    view.frame = contentView!.bounds
    view.textView.frame = contentView!.bounds
    view.textView.frame.size.width -= theme.pagingOffset
    view.textView.frame.origin.x += theme.pagingOffset
    view.textView.textContainerInset = theme.edgeInset

    if theme.translucency {
      back.frame = contentView!.bounds
      back.frame.size.width += theme.pagingOffset
      back.appearance = NSApp.effectiveAppearance
      back.isHidden = false
    } else {
      back.isHidden = true
    }
    alphaValue = theme.alpha
    invalidateShadow()
    orderFront(nil)
    // voila!
    // ✅ 修改这里： 统一的方法每次 UI 刷新时重新检查是否应该显示提示窗
    updateSchemaHints()
  }

  func show(status message: String) {
    let theme = view.currentTheme
    let text = NSMutableAttributedString(string: message, attributes: theme.attrs)
    text.addAttribute(.paragraphStyle, value: theme.paragraphStyle, range: NSRange(location: 0, length: text.length))
    view.textContentStorage.attributedString = text
    view.textView.setLayoutOrientation(vertical ? .vertical : .horizontal)
    view.drawView(candidateRanges: [NSRange(location: 0, length: text.length)], hilightedIndex: -1,
                  preeditRange: .empty, highlightedPreeditRange: .empty, canPageUp: false, canPageDown: false)
    show()

    statusTimer?.invalidate()
    statusTimer = Timer.scheduledTimer(withTimeInterval: SquirrelTheme.showStatusDuration, repeats: false) { _ in
      self.hide()
    }
  }

  func convert(range: Range<String.Index>, in string: String) -> NSRange {
    let startPos = range.lowerBound.utf16Offset(in: string)
    let endPos = range.upperBound.utf16Offset(in: string)
    return NSRange(location: startPos, length: endPos - startPos)
  }
}

// MARK: - DoublePinyinHintWindow (独立悬浮窗)

final class DoublePinyinHintWindow: NSPanel {
  
  private let hintView: KeyboardStyleHintView
  
  private struct HintConfig {
    let enabled: Bool
    
    static let `default` = HintConfig(enabled: true)
  }
  
  private var config = HintConfig.default
  
  // ✅ 新增：schema_id 到键位方案的映射表
  private static let schemaIdMapping: [String: String] = [
    "double_pinyin_flypy": "flypy",      // 小鹤双拼
    "double_pinyin": "natural",          // 自然码双拼
    "double_pinyin_mspy": "mspy",        // 微软双拼
    "double_pinyin_sogou": "sogou",         // ✅ 新增
    "double_pinyin_abc": "abc",       // 智能ABC双拼（通常等同小鹤）
    "double_pinyin_ziguang": "ziguang",   // 紫光双拼
    "double_pinyin_jiajia": "jiajia"        // ✅ 新增
  ]
  
  init() {
    self.hintView = KeyboardStyleHintView(frame: .zero)
    
    // 🔥 修改：增加初始高度 (140 -> 166)
    let initialFrame = NSRect(x: 0, y: 0, width: 580, height: 166)
    
    super.init(
      contentRect: initialFrame,
      styleMask: [.nonactivatingPanel, .borderless],
      backing: .buffered,
      defer: false
    )
    
    self.level = .floating
    self.isOpaque = false
    self.backgroundColor = .clear
    self.hasShadow = true
    self.ignoresMouseEvents = true
    
    self.contentView = hintView
    
    NSLog("✅ [Squirrel] DoublePinyinHintWindow created")
  }
  
  // ✅ 简化配置接口，只接收 enabled 开关
  func configure(enabled: Bool) {
    self.config = HintConfig(enabled: enabled)
    
    if !enabled {
      self.orderOut(nil)
    }
  }
  
  // ✅ 新增：根据 schema_id 自动推断并配置键位方案
  func updateScheme(from schemaId: String) {
    // 从映射表中查找对应的键位方案
    let scheme = Self.schemaIdMapping[schemaId] ?? "natural"  // 默认使用自然码
    
    hintView.configure(scheme: scheme)
    NSLog("📝 [Squirrel] Auto-detected scheme '\(scheme)' from schema_id '\(schemaId)'")
  }
  
  func isConfigEnabled() -> Bool {
    return config.enabled
  }
  
  func show(relativeTo candidateFrame: NSRect, onScreen screen: NSRect) {
    guard config.enabled else {
      self.orderOut(nil)
      return
    }
    
    let hintWidth: CGFloat = 580
    // 🔥 修改：增加显示高度 (139 -> 166)
    let hintHeight: CGFloat = 166
    
    // ✅ 两种间距：上方大间距（避免遮挡输入文字），下方小间距（节省空间）
    let spacingAbove: CGFloat = 8  // 在候选框上方时的间距
    let spacingBelow: CGFloat = 31   // 在候选框下方时的间距
    
    // ✅ 先判断应该放在上方还是下方
    let preferredY = candidateFrame.minY - hintHeight - spacingAbove
    let shouldPlaceAbove = preferredY >= screen.minY
    
    // ✅ 根据位置选择间距并计算坐标
    let spacing = shouldPlaceAbove ? spacingAbove : spacingBelow
    let finalY = shouldPlaceAbove
      ? candidateFrame.minY - hintHeight - spacing  // 上方
      : candidateFrame.maxY + spacing                // 下方
    
    var hintFrame = NSRect(
      x: candidateFrame.midX - hintWidth / 2,
      y: finalY,
      width: hintWidth,
      height: hintHeight
    )
    
    // ✅ 水平方向边界检查
    if hintFrame.minX < screen.minX {
      hintFrame.origin.x = screen.minX + 10
    }
    if hintFrame.maxX > screen.maxX {
      hintFrame.origin.x = screen.maxX - hintWidth - 10
    }
    
    // ✅ 垂直方向最终保护（极端情况下的兜底）
    if hintFrame.minY < screen.minY {
      hintFrame.origin.y = screen.minY + 10
    }
    if hintFrame.maxY > screen.maxY {
      hintFrame.origin.y = screen.maxY - hintHeight - 10
    }
    
    self.setFrame(hintFrame, display: true)
    self.orderFront(nil)
  }
  
  func hide() {
    self.orderOut(nil)
  }
}

// MARK: - KeyboardStyleHintView (键盘式参考图)

final class KeyboardStyleHintView: NSView {
  
  private var currentLayout: SchemeLayout?
  
  // ✅ 完整且准确的双拼方案数据
  private let schemeLayouts: [String: SchemeLayout] = [
    "natural": SchemeLayout(
      name: "自然码",
      rows: [
        [("Q", "iu"), ("W", "ia·ua"), ("E", "e"), ("R", "uan"), ("T", "ue·üe"), ("Y", "ing·uai"), ("U", "sh·u"), ("I", "ch·i"), ("O", "o·uo"), ("P", "un")],
        [("A", "a"), ("S", "ong·iong"), ("D", "uang·iang"), ("F", "en"), ("G", "eng"), ("H", "ang"), ("J", "an"), ("K", "ao"), ("L", "ai")],
        [("Z", "ei"), ("X", "ie"), ("C", "iao"), ("V", "zh·ui·ü"), ("B", "ou"), ("N", "in"), ("M", "ian")]
      ]
    ),
    
    "flypy": SchemeLayout(
      name: "小鹤双拼",
      rows: [
        [("Q", "iu"), ("W", "ei"), ("E", "e"), ("R", "uan"), ("T", "ue·üe"), ("Y", "un"), ("U", "sh·u"), ("I", "ch·i"), ("O", "o·uo"), ("P", "ie")],
        [("A", "a"), ("S", "iong·ong"), ("D", "ai"), ("F", "en"), ("G", "eng"), ("H", "ang"), ("J", "an"), ("K", "ing·uai"), ("L", "iang·uang")],
        [("Z", "ou"), ("X", "ia·ua"), ("C", "ao"), ("V", "zh·ui·ü"), ("B", "in"), ("N", "iao"), ("M", "ian")]
      ]
    ),
    
    "abc": SchemeLayout(
      name: "智能ABC",
      rows: [
        [("Q", "ei"), ("W", "ian"), ("E", "ch·e"), ("R", "er·iu"), ("T", "iang·uang"), ("Y", "ing"), ("U", "u"), ("I", "i"), ("O", "o·uo"), ("P", "uan")],
        [("A", "zh·a"), ("S", "iong·ong"), ("D", "ia·ua"), ("F", "en"), ("G", "eng"), ("H", "ang"), ("J", "an"), ("K", "ao"), ("L", "ai")],
        [("Z", "iao"), ("X", "ie"), ("C", "in·uai"), ("V", "sh·ü·üe"), ("B", "ou"), ("N", "un"), ("M", "ue·ui")]
      ]
    ),
    
    "mspy": SchemeLayout(
      name: "微软双拼",
      rows: [
        [("Q", "iu"), ("W", "ia·ua"), ("E", "e"), ("R", "uan"), ("T", "ue"), ("Y", "uai·ü"), ("U", "sh·u"), ("I", "ch·i"), ("O", "o·uo"), ("P", "un")],
        [("A", "a"), ("S", "iong·ong"), ("D", "iang·uang"), ("F", "en"), ("G", "eng"), ("H", "ang"), ("J", "an"), ("K", "ao"), ("L", "ai"), (";", "ing")],
        [("Z", "ei"), ("X", "ie"), ("C", "iao"), ("V", "zh·ui·üe"), ("B", "ou"), ("N", "in"), ("M", "ian")]
      ]
    ),
    
    "ziguang": SchemeLayout(
      name: "紫光双拼",
      rows: [
        [("Q", "ao"), ("W", "en"), ("E", "e"), ("R", "an"), ("T", "eng"), ("Y", "in·uai"), ("U", "zh·u"), ("I", "sh·i"), ("O", "o·uo"), ("P", "ai")],
        [("A", "ch·a"), ("S", "ang"), ("D", "ie"), ("F", "ian"), ("G", "iang·uang"), ("H", "iong·ong"), ("J", "er·iu"), ("K", "ei"), ("L", "uan"), (";", "ing")],
        [("Z", "ou"), ("X", "ia·ua"), ("V", "ü"), ("B", "iao"), ("N", "ue·ui"), ("M", "un")]
      ]
    ),
    
    // ✅ 新增：搜狗双拼（与微软基本相同）
    "sogou": SchemeLayout(
      name: "搜狗双拼",
      rows: [
        [("Q", "iu"), ("W", "ia·ua"), ("E", "e"), ("R", "er·uan"), ("T", "ue·üe"), ("Y", "uai·ü"), ("U", "sh·u"), ("I", "ch·i"), ("O", "o·uo"), ("P", "un")],
        [("A", "a"), ("S", "iong·ong"), ("D", "iang·uang"), ("F", "en"), ("G", "eng"), ("H", "ang"), ("J", "an"), ("K", "ao"), ("L", "ai"), (";", "ing")],
        [("Z", "ei"), ("X", "ie"), ("C", "iao"), ("V", "zh·ui"), ("B", "ou"), ("N", "in"), ("M", "ian")]
      ]
    ),
    
    // ✅ 新增：拼音加加
    "jiajia": SchemeLayout(
      name: "加加双拼",
      rows: [
        [("Q", "er·ing"), ("W", "ei"), ("E", "e"), ("R", "en"), ("T", "eng"), ("Y", "iong·ong"), ("U", "ch·u"), ("I", "sh·i"), ("O", "uo·o"), ("P", "ou")],
        [("A", "a"), ("S", "ai"), ("D", "ao"), ("F", "an"), ("G", "ang"), ("H", "iang·uang"), ("J", "ian"), ("K", "iao"), ("L", "in")],
        [("Z", "un"), ("X", "uai·ue"), ("C", "uan"), ("V", "zh·ü·ui"), ("B", "ia·ua"), ("N", "iu"), ("M", "ie")]
      ]
    )
  ]
  
  private struct SchemeLayout {
    let name: String
    let rows: [[(letter: String, vowel: String)]]
  }
  
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    self.wantsLayer = true
    self.layer?.cornerRadius = 10
  }
  
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
  
  func configure(scheme: String) {
    self.currentLayout = schemeLayouts[scheme]
    self.needsDisplay = true
  }
  
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    
    guard let layout = currentLayout else { return }
    
    // ✅ 毛玻璃背景
    let bgColor = NSColor.controlBackgroundColor.withAlphaComponent(0.98)
    bgColor.setFill()
    let bgPath = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
    bgPath.fill()
    
    // ✅ 边框
    NSColor.separatorColor.withAlphaComponent(0.3).setStroke()
    let borderPath = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
    borderPath.lineWidth = 1
    borderPath.stroke()
    
    let padding: CGFloat = 16
    // 掉标题后，从更靠上的位置开始绘制键盘
    var y = bounds.height - padding - 39  // 原来是 -20（标题高度），现在只需 -10
    
    // ✅ 绘制三行键盘
    for row in layout.rows {
      drawKeyboardRow(row: row, y: y, padding: padding)
      y -= 48
    }
    
    // 🔥 在右下角显示方案名称（M键右侧）
    let nameAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 10, weight: .medium),
      .foregroundColor: NSColor.tertiaryLabelColor
    ]
    let nameSize = layout.name.size(withAttributes: nameAttrs)
    
    // 计算位置：右下角，稍微留点边距
    let nameX = bounds.width - padding - nameSize.width
    let nameY = padding + 4  // 稍微抬高一点，与最后一行对齐
    
    layout.name.draw(at: NSPoint(x: nameX, y: nameY), withAttributes: nameAttrs)
}
  
  // ✅ 绘制一行键盘（模拟真实键盘样式）
  private func drawKeyboardRow(row: [(letter: String, vowel: String)], y: CGFloat, padding: CGFloat) {
    let keyWidth: CGFloat = 52
    let keyHeight: CGFloat = 44
    let keySpacing: CGFloat = 4
    let rowWidth = CGFloat(row.count) * (keyWidth + keySpacing) - keySpacing
    var x = (bounds.width - rowWidth) / 2
    
   let unifiedVowelSize: CGFloat = 12  // 统一使用 11.5 号字体
    for key in row {
      // ✅ 按键背景（渐变效果）
      let keyRect = NSRect(x: x, y: y, width: keyWidth, height: keyHeight)
      let keyPath = NSBezierPath(roundedRect: keyRect, xRadius: 4, yRadius: 4)
      
      // 渐变背景
      NSColor.systemGray.withAlphaComponent(0.15).setFill()
      keyPath.fill()
      
      // 按键边框
      NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
      keyPath.lineWidth = 0.5
      keyPath.stroke()
      
    // 🔥 优化1：26字母改为左下角显示
    let letterAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 9, weight: .medium),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    key.letter.draw(at: NSPoint(x: x + 4, y: y + 4), withAttributes: letterAttrs)
    
    // ✅ 韵母绘制逻辑
    let rawVowel = key.vowel
    let parts = rawVowel.components(separatedBy: "·")
    
    if parts.count > 1 {
      // 🔥 优化2：多行绘制模式（右上角、右对齐、上对齐）
      let lineHeight: CGFloat = 13
      let rightPadding: CGFloat = 4
      let topPadding: CGFloat = 4
      
      // 从顶部开始绘制（上对齐）
      var currentY = y + keyHeight - topPadding - lineHeight
      
      for part in parts {
        // 检查是否是声母（zh/ch/sh）
        let isInitial = ["zh", "ch", "sh"].contains(part)
        
        let stackAttrs: [NSAttributedString.Key: Any] = [
          .font: isInitial
            ? NSFont.systemFont(ofSize: unifiedVowelSize, weight: .semibold)
            : NSFont.systemFont(ofSize: unifiedVowelSize, weight: .medium),
          .foregroundColor: isInitial ? NSColor.systemBlue : NSColor.labelColor
        ]
        
        let partSize = part.size(withAttributes: stackAttrs)
        let partX = x + keyWidth - partSize.width - rightPadding
        
        part.draw(at: NSPoint(x: partX, y: currentY), withAttributes: stackAttrs)
        
        // 向下移动到下一行
        currentY -= lineHeight
      }
      
    } else {
      // 🔥 优化2：单行绘制模式（右上角、右对齐）
      let rightPadding: CGFloat = 4
      let topPadding: CGFloat = 4
      
      // 🔥 优化3：使用 NSAttributedString 处理声母高亮
      let attributedVowel = NSMutableAttributedString(string: rawVowel)
      
      // 默认属性
      let defaultAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: unifiedVowelSize, weight: .medium),
        .foregroundColor: NSColor.labelColor
      ]
      attributedVowel.addAttributes(defaultAttrs, range: NSRange(location: 0, length: rawVowel.count))
      
      // 高亮声母 zh/ch/sh（蓝色粗体）
      let initials = ["zh", "ch", "sh"]
      for initial in initials {
        if let range = rawVowel.range(of: initial) {
          let nsRange = NSRange(range, in: rawVowel)
          attributedVowel.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: nsRange)
          attributedVowel.addAttribute(.font, value: NSFont.systemFont(ofSize: unifiedVowelSize, weight: .semibold), range: nsRange)
        }
      }
      
      let vowelSize = attributedVowel.size()
      let vowelX = x + keyWidth - vowelSize.width - rightPadding
      let vowelY = y + keyHeight - vowelSize.height - topPadding
      
      attributedVowel.draw(at: NSPoint(x: vowelX, y: vowelY))
    }
    
    // 移到下一个按键
      x += keyWidth + keySpacing
    }
  }
}


// MARK: - Wubi
final class WubiHintWindow: NSPanel, SchemaHintWindow {

    private let wubiView: WubiKeyboardLayoutView
    private var enabled: Bool = true

    init() {
        self.wubiView = WubiKeyboardLayoutView(frame: .zero)

        let frame = NSRect(x: 0, y: 0, width: 720, height: 260)
        super.init(
            contentRect: frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.contentView = wubiView
    }

    func configure(enabled: Bool) {
        self.enabled = enabled
        if !enabled { hide() }
    }

    func updateScheme(from schemaId: String) {
        // 五笔一般 schema_id 包含 "wubi"
        guard schemaId.contains("wubi") else { return }

        // 这里可以进一步区分 86 / 98 / 新世纪
        // 暂时默认新世纪
        wubiView.setSchemeData(WubiDataFactory.getXinShiJiData())
    }

    func isConfigEnabled() -> Bool {
        enabled
    }

    func show(relativeTo candidateFrame: NSRect, onScreen screen: NSRect) {
        guard enabled else { return }

        let width: CGFloat = 820
        let height: CGFloat = 280
        
        // ✅ 两种间距：上方大间距（避免遮挡输入文字），下方小间距（节省空间）
        let spacingAbove: CGFloat = 8   // 在候选框上方时的间距
        let spacingBelow: CGFloat = 31  // 在候选框下方时的间距
        
        // ✅ 先判断应该放在上方还是下方（优先上方）
        let preferredY = candidateFrame.minY - height - spacingAbove
        let shouldPlaceAbove = preferredY >= screen.minY
        
        // ✅ 根据位置选择间距并计算坐标
        let spacing = shouldPlaceAbove ? spacingAbove : spacingBelow
        let finalY = shouldPlaceAbove
            ? candidateFrame.minY - height - spacing  // 上方
            : candidateFrame.maxY + spacing           // 下方
        
        var frame = NSRect(
            x: candidateFrame.midX - width / 2,
            y: finalY,
            width: width,
            height: height
        )

        // ✅ 水平方向边界检查
        if frame.minX < screen.minX {
            frame.origin.x = screen.minX + 10
        }
        if frame.maxX > screen.maxX {
            frame.origin.x = screen.maxX - width - 10
        }
        
        // ✅ 垂直方向最终保护（极端情况下的兜底）
        if frame.minY < screen.minY {
            frame.origin.y = screen.minY + 10
        }
        if frame.maxY > screen.maxY {
            frame.origin.y = screen.maxY - height - 10
        }

        setFrame(frame, display: true)
        orderFront(nil)
    }

    func hide() {
        orderOut(nil)
    }
}


///
///
///
///
///
///
///
///
///
///
///
///

//
//  WubiComponents.swift
//  WubiDesigner
//
//  Created on 2025/12/30.
//
// MARK: - 1. 核心数据模型

/// 五笔按键数据结构（新世纪版）
struct WubiKeyData {
    let key: String        // 键名 (Q, W...)
    let mainRoot: String   // 主字根 (大字)
    let highlightRoot: String    // 重点字根 (右上角带圆圈，可为空；以"-"包裹则不显示圆圈)
    let primaryGroup: [String]   // 主组字根（第一行，重点显示）
    let secondaryRoots: [String] // 次要字根（第二行开始；以"-"包裹则显示矩形边框）
    let keyCode: Int       // 区位码（用于显示）
    let zone: Int          // 分区: 0:特殊, 1:横(G-A), 2:竖(H-M), 3:撇(T-Q), 4:捺(Y-P), 5:折(N-X)
}

// MARK: - 2. 字体工具扩展

private extension NSFont {
    /// 获取适合显示部首的字体
    /// 策略：楷体(完整度高/传统感) -> 宋体(字典感) -> 苹方(保底)
    static func wubiRootFont(size: CGFloat) -> NSFont {
        // 优先推荐：楷体 (Kaiti SC)。它对 CJK 部首的支持非常完整，且字形结构舒展，非常适合做字根表。
        if let font = NSFont(name: "Kaiti SC", size: size) { return font }
        
        // 备选：宋体 (Songti SC)。
        if let font = NSFont(name: "Songti SC", size: size) { return font }
        
        // 保底：系统字体。
        return NSFont.systemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - 2.5 字符串处理辅助

/// 局部显示配置（用于显示字的一部分）
struct PartialDisplayConfig {
    let character: String      // 要显示的完整字符
    let xStart: CGFloat        // X起始位置（比例 0-1）
    let xEnd: CGFloat          // X结束位置（比例 0-1）
    let yStart: CGFloat        // Y起始位置（比例 0-1）
    let yEnd: CGFloat          // Y结束位置（比例 0-1）
    let maskRects: [CGRect]    // 差集遮挡区域（后期扩展，坐标为比例值）
    
    init(character: String, xStart: CGFloat, xEnd: CGFloat, yStart: CGFloat, yEnd: CGFloat, maskRects: [CGRect] = []) {
        self.character = character
        self.xStart = min(max(xStart, 0), 1)
        self.xEnd = min(max(xEnd, 0), 1)
        self.yStart = min(max(yStart, 0), 1)
        self.yEnd = min(max(yEnd, 0), 1)
        self.maskRects = maskRects
    }
}

private extension String {
    /// 检测字符串是否被 "-" 包裹
    var isWrappedWithDash: Bool {
        return self.hasPrefix("-") && self.hasSuffix("-") && self.count > 2
    }
    
    /// 去掉开头和结尾的 "-"
    var unwrappedDash: String {
        if isWrappedWithDash {
            let startIndex = self.index(after: self.startIndex)
            let endIndex = self.index(before: self.endIndex)
            return String(self[startIndex..<endIndex])
        }
        return self
    }
    
    /// 检测是否是局部显示格式：+字+x1+x2+y1+y2+
    var isPartialDisplayFormat: Bool {
        return self.hasPrefix("+") && self.hasSuffix("+") && self.count > 4
    }
    
    /// 解析局部显示配置
    /// 格式：+歆+0.333+0.666+0.222+0.5555+
    /// 后期可扩展差集：+歆+0.333+0.666+0.222+0.5555+[0.4,0.3,0.1,0.1]+
    /// 差集格式说明：[x,y,width,height] 都是比例值（0-1），相对于完整字符的坐标系
    func parsePartialDisplay() -> PartialDisplayConfig? {
        guard isPartialDisplayFormat else { return nil }
        
        // 去掉首尾的 "+"
        let content = String(self.dropFirst().dropLast())
        
        // 按 "+" 分割
        let components = content.split(separator: "+").map(String.init)
        
        // 至少需要 5 个部分：字符 + x1 + x2 + y1 + y2
        guard components.count >= 5 else { return nil }
        
        let character = components[0]
        guard character.count == 1 else { return nil } // 必须是单个字符
        
        // 解析坐标
        guard let x1 = Double(components[1]),
              let x2 = Double(components[2]),
              let y1 = Double(components[3]),
              let y2 = Double(components[4]) else {
            return nil
        }
        
        // 解析差集遮挡区域（后期扩展）
        var maskRects: [CGRect] = []
        if components.count > 5 {
            // 解析差集格式，例如：[0.4,0.3,0.1,0.1] 表示 x,y,width,height（比例值）
            for i in 5..<components.count {
                let maskStr = components[i]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                let values = maskStr.split(separator: ",").compactMap { Double($0) }
                if values.count == 4 {
                    maskRects.append(CGRect(x: values[0], y: values[1],
                                           width: values[2], height: values[3]))
                }
            }
        }
        
        return PartialDisplayConfig(
            character: character,
            xStart: CGFloat(x1),
            xEnd: CGFloat(x2),
            yStart: CGFloat(y1),
            yEnd: CGFloat(y2),
            maskRects: maskRects
        )
    }


    /// 是否强制纯文本（不显示圆徽章）
    var isForcePlainHighlight: Bool {
        return self.hasPrefix("!")
    }

    /// 去掉所有用于 UI 的前缀标志（目前只有 !）
    var highlightContent: String {
        if self.hasPrefix("!") {
            return String(self.dropFirst())
        }
        return self
    }
}


// MARK: - 3. AppKit 绘图视图 (核心 UI)

final class WubiKeyboardLayoutView: NSView {
    
    // ================= 配置区域 (在此微调) =================
    
    // 布局间距
    private let padding: CGFloat = 8          // 整体内边距
    private let keySpacing: CGFloat = 4        // 按键间距
    private let keyCornerRadius: CGFloat = 6.0 // 按键圆角
    
    // 字体基准大小
    private let baseMainRootSize: CGFloat = 25.0 // 主字根最大字号 (会动态缩小)
    private let highlightRootSize: CGFloat = 13.6     // 重点字根（圆圈内）
    private let primaryGroupFontSize: CGFloat = 13  // 主组字根
    private let secondaryRootFontSize: CGFloat = 13 // 次要字根
    private let keyLabelFontSize: CGFloat = 11.0 // 左上角字母
    private let keyCodeFontSize: CGFloat = 9.0   // 区位码
    
    private func zoneColor(for zone: Int) -> NSColor? {
        let palette = isDarkMode ? zoneColorsDark : zoneColors
        return palette[zone]
    }
    
    // 分区背景色 (采用低饱和度莫兰迪色系，久看不累)
    private let zoneColors: [Int: NSColor] = [
        0: NSColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 0.35),                                           // 0区 特殊键/学习键 (透明)
        1: NSColor(red: 0.95, green: 0.63, blue: 0.56, alpha: 1.0), // 1区 横 (橙红色系)
        2: NSColor(red: 0.67, green: 0.82, blue: 0.67, alpha: 1.0), // 2区 竖 (豆绿色系)
        3: NSColor(red: 0.64, green: 0.78, blue: 0.88, alpha: 1.0), // 3区 撇 (淡青蓝系)
        4: NSColor(red: 0.86, green: 0.70, blue: 0.86, alpha: 1.0), // 4区 捺 (粉紫色系)
        5: NSColor(red: 0.96, green: 0.92, blue: 0.66, alpha: 1.0)  // 5区 折 (黄系)
    ]
    
    // 深色模式：降低亮度、略降饱和度，避免荧光感；alpha 稍降以融入暗底
    private var zoneColorsDark: [Int: NSColor] = [
        0: NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.20, alpha: 0.35),
        1: NSColor(calibratedRed: 0.46, green: 0.27, blue: 0.24, alpha: 1.0), // 暗橙红
        2: NSColor(calibratedRed: 0.26, green: 0.39, blue: 0.27, alpha: 1.0), // 暗豆绿
        3: NSColor(calibratedRed: 0.23, green: 0.33, blue: 0.42, alpha: 1.0), // 暗青蓝
        4: NSColor(calibratedRed: 0.38, green: 0.27, blue: 0.38, alpha: 1.0), // 暗暖紫
        5: NSColor(calibratedRed: 0.43, green: 0.40, blue: 0.24, alpha: 1.0)  // 暗米黄
    ]
    
    private var isDarkMode: Bool {
        if #available(macOS 10.14, *) {
            return effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        } else {
            return false
        }
    }
    
    private func applyAppearance() {
        // 🔥 修复：深色模式使用深色背景，浅色模式使用系统背景
        if isDarkMode {
            // 深色模式：使用深灰黑色背景（接近系统深色主题）
            layer?.backgroundColor = NSColor(calibratedWhite: 0.18, alpha: 0.98).cgColor
        } else {
            // 浅色模式：使用系统背景色
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }

        // 边框：深色模式略提亮一点，避免"看不见"
        let borderAlpha: CGFloat = isDarkMode ? 0.55 : 0.40
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(borderAlpha).cgColor
    }


    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
        needsDisplay = true
    }
    
    // MARK: - Highlight Badge Colors (按分区)

    private var highlightStrokeColorsLight: [Int: NSColor] = [
        1: NSColor(calibratedRed: 0.88, green: 0.45, blue: 0.30, alpha: 1.0), // 橙
        2: NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.82, alpha: 1.0), // 青蓝
        3: NSColor(calibratedRed: 0.35, green: 0.62, blue: 0.82, alpha: 1.0), // 青蓝
        4: NSColor(calibratedRed: 0.64, green: 0.44, blue: 0.72, alpha: 1.0), // 紫
        5: NSColor(calibratedRed: 0.85, green: 0.60, blue: 0.32, alpha: 1.0)  // 浅橙
    ]

    private var highlightStrokeColorsDark: [Int: NSColor] = [
        1: NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.42, alpha: 1.0),
        2: NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.90, alpha: 1.0),
        3: NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.90, alpha: 1.0),
        4: NSColor(calibratedRed: 0.78, green: 0.62, blue: 0.86, alpha: 1.0),
        5: NSColor(calibratedRed: 0.92, green: 0.72, blue: 0.46, alpha: 1.0)
    ]

    private func highlightStrokeColor(for zone: Int) -> NSColor {
        let palette = isDarkMode ? highlightStrokeColorsDark : highlightStrokeColorsLight
        return palette[zone] ?? NSColor.labelColor
    }
    
    // ====================================================
    
    // 数据源
    private var layoutData: [[WubiKeyData]] = WubiDataFactory.getXinShiJiData()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.wantsLayer = true
        self.layer?.cornerRadius = 12
        self.layer?.masksToBounds = true
        /*
        // 键盘底板颜色
        self.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        // 键盘外边框
        self.layer?.borderWidth = 0.5
        self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.4).cgColor
         */
        applyAppearance()

    }
    
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    
    // 供外部调用更新数据
    func setSchemeData(_ data: [[WubiKeyData]]) {
        self.layoutData = data
        self.needsDisplay = true
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        guard !layoutData.isEmpty else { return }
        
        // 1. 计算网格尺寸
        // 找出最长的一行来确定列宽（通常是第一行 Q-P，10个键）
        let maxKeysInRow = CGFloat(layoutData.map { $0.count }.max() ?? 10)
        
        let totalHorizontalSpacing = (maxKeysInRow - 1) * keySpacing + padding * 2
        let keyWidth = (bounds.width - totalHorizontalSpacing) / maxKeysInRow
        
        // 3行按键 + 上下 Padding + 2个行间距
        let totalVerticalSpacing = padding * 2 + keySpacing * 2
        let keyHeight = (bounds.height - totalVerticalSpacing) / 3
        
        var y = bounds.height - padding - keyHeight
        
        // 2. 逐行绘制
        for row in layoutData {
            // 计算当前行的起始 X，确保居中
            let rowWidth = CGFloat(row.count) * keyWidth + CGFloat(row.count - 1) * keySpacing
            var x = (bounds.width - rowWidth) / 2
            
            for keyData in row {
                let keyRect = NSRect(x: x, y: y, width: keyWidth, height: keyHeight)
                drawKey(rect: keyRect, data: keyData)
                x += keyWidth + keySpacing
            }
            
            y -= (keyHeight + keySpacing)
        }
    }
    
    // 绘制单个按键
    private func drawKey(rect: NSRect, data: WubiKeyData) {
        let path = NSBezierPath(roundedRect: rect, xRadius: keyCornerRadius, yRadius: keyCornerRadius)
        
        // A. 填充背景色
        /*
        if let color = zoneColors[data.zone] {
            color.withAlphaComponent(0.65).setFill()
            path.fill()
        }
         */
        
         if let color = zoneColor(for: data.zone) {
             // 深色模式稍微更实一点（不然会“脏灰”）
             let fillAlpha: CGFloat = isDarkMode ? 0.72 : 0.65
             color.withAlphaComponent(fillAlpha).setFill()
             path.fill()
         }

        
        // B. 描边
        // NSColor.separatorColor.withAlphaComponent(0.2).setStroke()
        let strokeAlpha: CGFloat = isDarkMode ? 0.32 : 0.20
        NSColor.separatorColor.withAlphaComponent(strokeAlpha).setStroke()

        path.lineWidth = 1.0
        path.stroke()
        
        // === 第一行：左上角字母 + 右上角区位码 ===
        drawKeyLabel(data.key, in: rect)
        if data.keyCode > 0 {
            drawKeyCode(data.keyCode, in: rect)
        }
        
        // === 布局参数 ===
    let horizontalPadding: CGFloat = 4
    let verticalPadding: CGFloat = 3
    
    // 计算第一行实际高度（文本高度 + 顶部间距）
    let labelFont = NSFont.systemFont(ofSize: keyLabelFontSize, weight: .bold)
    let labelHeight = labelFont.ascender - labelFont.descender
    let row1Height = labelHeight + 3  // 减小间距
    
    let row2Height: CGFloat = 28  // 固定高度，不再用百分比
    let rowSpacing: CGFloat = 2  // 行间距
    
    // === 第二行：主字根(左) + primaryGroup第一行(中) + 重点字根(右) ===
    // 紧挨着第一行
    let row2Top = rect.maxY - row1Height
    let row2Rect = NSRect(
        x: rect.minX + horizontalPadding,
        y: row2Top - row2Height,
        width: rect.width - horizontalPadding * 2,
        height: row2Height
    )
    
    drawRow2(mainRoot: data.mainRoot,
             primaryGroup: data.primaryGroup,
             highlightRoot: data.highlightRoot,
             zone: data.zone,
             in: row2Rect)
    
    var currentY = row2Rect.minY - rowSpacing
    
    // === 第三行：primaryGroup第二行（如果存在，使用全宽） ===
        let primaryRow2 = getPrimaryGroupRow2(data.primaryGroup, in: row2Rect)
        if !primaryRow2.isEmpty {
            let row3Height: CGFloat = 14
            let row3Rect = NSRect(
                x: rect.minX + horizontalPadding,
                y: currentY - row3Height,
                width: rect.width - horizontalPadding * 2,
                height: row3Height
            )
            drawPrimaryGroupRow2(primaryRow2, in: row3Rect)
            currentY = row3Rect.minY - rowSpacing
        }
        
        // === 第四行：secondaryRoots（使用全宽） ===
        if !data.secondaryRoots.isEmpty {
            let secondaryHorizontalPadding: CGFloat = 3.6  // 增加左右边距
            let row4Rect = NSRect(
                x: rect.minX + secondaryHorizontalPadding,
                y: verticalPadding,
                width: rect.width - secondaryHorizontalPadding * 2,
                height: currentY - verticalPadding
            )
            drawSecondaryRoots(data.secondaryRoots, in: row4Rect)
        }

    }

    // 辅助方法：获取 primaryGroup 第二行的元素
    // 🔧 修复：辅助方法正确计算局部显示字符的宽度
    private func getPrimaryGroupRow2(_ primaryGroup: [String], in rect: NSRect) -> [String] {
        guard !primaryGroup.isEmpty else { return [] }
        
        let font = NSFont.wubiRootFont(size: primaryGroupFontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        
        // 中间区域宽度（扣除左侧主字根30% + 右侧重点字根20%）
        let middleWidth = rect.width * 0.50
        let spacing: CGFloat = 3
        
        var currentX: CGFloat = 0
        var row1Elements: [String] = []
        
        for root in primaryGroup {
            // ⭐ 关键修复：正确计算局部显示字符的实际显示宽度
            let displayWidth: CGFloat
            if let config = root.parsePartialDisplay() {
                let fullSize = config.character.size(withAttributes: attrs)
                displayWidth = fullSize.width * (config.xEnd - config.xStart)
            } else {
                displayWidth = root.size(withAttributes: attrs).width
            }
            
            if currentX + displayWidth > middleWidth {
                break  // 第一行已满
            }
            row1Elements.append(root)
            currentX += displayWidth + spacing
        }
        
        // 返回剩余元素作为第二行
        return Array(primaryGroup.dropFirst(row1Elements.count))
    }

    // 绘制第二行：主字根(左) + primaryGroup第一行(中) + 重点字根(右)
    private func drawRow2(mainRoot: String, primaryGroup: [String], highlightRoot: String, zone: Int, in rect: NSRect) {
        // 左侧 30%：主字根
        let mainRootWidth = rect.width * 0.30
        drawMainRootInRect(mainRoot, in: NSRect(
            x: rect.minX,
            y: rect.minY,
            width: mainRootWidth,
            height: rect.height
        ))
        
        // 右侧 20%：重点字根
        let highlightWidth = rect.width * 0.20
        if !highlightRoot.isEmpty {
            drawHighlightRootInRect(highlightRoot, in: NSRect(
                x: rect.maxX - highlightWidth,
                y: rect.minY,
                width: highlightWidth,
                height: rect.height
            ),
            zone: zone
            )
        }
        
        // 中间 50%：primaryGroup 第一行
        let middleRect = NSRect(
            x: rect.minX + mainRootWidth,
            y: rect.minY,
            width: rect.width * 0.50,
            height: rect.height
        )
        drawPrimaryGroupRow1(primaryGroup, in: middleRect)
    }

    // ===== 核心功能：绘制带局部显示的字符 =====
    /// 绘制字符（支持局部显示和差集遮挡）
    /// - Parameters:
    ///   - text: 要绘制的文本（可能是普通字符或局部显示格式）
    ///   - rect: 绘制区域
    ///   - fontSize: 字体大小
    ///   - color: 文本颜色
    ///   - alignment: 对齐方式（默认居中）
    private func drawText(_ text: String, in rect: NSRect, fontSize: CGFloat,
                         color: NSColor, alignment: NSTextAlignment = .center) {
        // 检查是否是局部显示格式
        if let config = text.parsePartialDisplay() {
            drawPartialCharacter(config: config, in: rect, fontSize: fontSize, color: color, alignment: alignment)
        } else {
            // 普通绘制
            let font = NSFont.wubiRootFont(size: fontSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color
            ]
            let size = text.size(withAttributes: attrs)
            
            let x: CGFloat
            switch alignment {
            case .center:
                x = rect.minX + (rect.width - size.width) / 2
            case .left:
                x = rect.minX
            case .right:
                x = rect.maxX - size.width
            default:
                x = rect.minX + (rect.width - size.width) / 2
            }
            
            let y = rect.minY + (rect.height - size.height) / 2
            text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
        }
    }
    
    /// 绘制局部显示的字符
    private func drawPartialCharacter(config: PartialDisplayConfig, in rect: NSRect,
                                     fontSize: CGFloat, color: NSColor, alignment: NSTextAlignment) {
        // 1. 计算完整字符的尺寸
        let font = NSFont.wubiRootFont(size: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let fullSize = config.character.size(withAttributes: attrs)
        
        // 2. 计算字符的绘制起点（居中）
        let charX: CGFloat
        switch alignment {
        case .center:
            charX = rect.minX + (rect.width - fullSize.width) / 2
        case .left:
            charX = rect.minX
        case .right:
            charX = rect.maxX - fullSize.width
        default:
            charX = rect.minX + (rect.width - fullSize.width) / 2
        }
        let charY = rect.minY + (rect.height - fullSize.height) / 2
        let charOrigin = NSPoint(x: charX, y: charY)
        
        // 3. 计算裁剪区域（基于比例值转换为实际坐标）
        let clipX = charX + fullSize.width * config.xStart
        let clipY = charY + fullSize.height * config.yStart
        let clipWidth = fullSize.width * (config.xEnd - config.xStart)
        let clipHeight = fullSize.height * (config.yEnd - config.yStart)
        let clipRect = NSRect(x: clipX, y: clipY, width: clipWidth, height: clipHeight)
        
        // 4. 保存图形上下文
        NSGraphicsContext.saveGraphicsState()
        
        // 5. 创建裁剪路径
        let clipPath = NSBezierPath(rect: clipRect)
        
        // 6. 如果有差集遮挡，从裁剪区域中减去
        if !config.maskRects.isEmpty {
            for maskRect in config.maskRects {
                // 将比例坐标转换为实际坐标
                let maskX = charX + fullSize.width * maskRect.origin.x
                let maskY = charY + fullSize.height * maskRect.origin.y
                let maskWidth = fullSize.width * maskRect.width
                let maskHeight = fullSize.height * maskRect.height
                let actualMaskRect = NSRect(x: maskX, y: maskY, width: maskWidth, height: maskHeight)
                
                // 使用 Even-Odd 规则实现差集（减去遮挡区域）
                clipPath.windingRule = .evenOdd
                clipPath.append(NSBezierPath(rect: actualMaskRect))
            }
        }
        
        // 7. 设置裁剪
        clipPath.addClip()
        
        // 8. 绘制完整字符（只有裁剪区域内的部分会显示）
        config.character.draw(at: charOrigin, withAttributes: attrs)
        
        // 9. 恢复图形上下文
        NSGraphicsContext.restoreGraphicsState()
        
        // 10. 可选：绘制调试边框（开发时用，正式版可注释掉）
        #if DEBUG
        // 绘制裁剪区域边框（绿色）
        NSColor.green.withAlphaComponent(0.3).setStroke()
        NSBezierPath(rect: clipRect).lineWidth = 0.5
        NSBezierPath(rect: clipRect).stroke()
        
        // 绘制遮挡区域边框（红色）
        NSColor.red.withAlphaComponent(0.3).setStroke()
        for maskRect in config.maskRects {
            let maskX = charX + fullSize.width * maskRect.origin.x
            let maskY = charY + fullSize.height * maskRect.origin.y
            let maskWidth = fullSize.width * maskRect.width
            let maskHeight = fullSize.height * maskRect.height
            let actualMaskRect = NSRect(x: maskX, y: maskY, width: maskWidth, height: maskHeight)
            NSBezierPath(rect: actualMaskRect).lineWidth = 0.5
            NSBezierPath(rect: actualMaskRect).stroke()
        }
        #endif
    }
    // 绘制主字根（在指定矩形内）- 改为靠上对齐
    private func drawMainRootInRect(_ root: String, in rect: NSRect) {
        guard !root.isEmpty && root != " " else { return }
        
        let maxW = rect.width * 0.99
        let maxH = rect.height * 0.99
        
        var fontSize = baseMainRootSize
        var font = NSFont.wubiRootFont(size: fontSize)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.92)
        ]
        var size = root.size(withAttributes: attrs)
        
        // 动态缩放
        while (size.width > maxW || size.height > maxH) && fontSize > 14 {
            fontSize -= 0.5
            font = NSFont.wubiRootFont(size: fontSize)
            attrs[.font] = font
            size = root.size(withAttributes: attrs)
        }
        
        // 使用新的绘制方法（支持局部显示）
        let drawRect = NSRect(x: rect.minX, y: rect.maxY - size.height + 5,
                             width: rect.width, height: size.height)
        drawText(root, in: drawRect, fontSize: fontSize,
                color: NSColor.labelColor.withAlphaComponent(0.92), alignment: .center)
    }

    // 绘制重点字根（在指定矩形内）- 使用新的绘制方法 + 分区彩色徽章
    private func drawHighlightRootInRect(_ root: String, in rect: NSRect, zone: Int) {
        // let isWrapped = root.isWrappedWithDash
        // let displayText = isWrapped ? root.unwrappedDash : root

        let forcePlain = root.isForcePlainHighlight
        let cleanRoot = root.highlightContent

        let isWrapped = cleanRoot.isWrappedWithDash
        let displayText = isWrapped ? cleanRoot.unwrappedDash : cleanRoot

        if forcePlain || isWrapped {    ///if isWrapped {
                // 直接显示，不加圆圈
                drawText(displayText,
            in: NSRect(x: rect.minX, y: rect.maxY - highlightRootSize - 1,
                                                width: rect.width, height: highlightRootSize),
                        fontSize: highlightRootSize,
                        color: NSColor.labelColor.withAlphaComponent(0.85),
                        alignment: .center)
            } else {
                // 显示圆圈
            // 显示彩色徽章：背景=键帽底色，边框/字=分区强调色
            let circleSize: CGFloat = 15
            let circleRect = NSRect(
                x: rect.minX + (rect.width - circleSize) / 2,
                y: rect.maxY - circleSize - 1,
                width: circleSize,
                height: circleSize
            )

            let circlePath = NSBezierPath(ovalIn: circleRect)

            // 1) 填充：使用键盘最底层背景色（镂空效果）
            let backgroundColor = NSColor.windowBackgroundColor
            backgroundColor.setFill()
            circlePath.fill()

            // 2) 边框：分区强调色
            let stroke = highlightStrokeColor(for: zone)
            stroke.setStroke()
            circlePath.lineWidth = 1.1
            circlePath.stroke()

            // 3) 文字：同边框色（彩色字）
            drawText(
                displayText,
                in: circleRect,
                fontSize: highlightRootSize,
                color: stroke,
                alignment: .center
            )
        }
    }


// 绘制 primaryGroup 第一行（左对齐）- 改为靠上对齐
    private func drawPrimaryGroupRow1(_ primaryGroup: [String], in rect: NSRect) {
        guard !primaryGroup.isEmpty else { return }
        
        let font = NSFont.wubiRootFont(size: primaryGroupFontSize)
        let lineHeight = font.ascender - font.descender
        var currentX = rect.minX
        let y = rect.maxY - lineHeight - 1
        let spacing: CGFloat = 3
        
        for root in primaryGroup {
            // 检查是否是局部显示格式
            let displayWidth: CGFloat
            if let config = root.parsePartialDisplay() {
                let fullSize = config.character.size(withAttributes: [.font: font])
                displayWidth = fullSize.width * (config.xEnd - config.xStart)
            } else {
                displayWidth = root.size(withAttributes: [.font: font]).width
            }
            
            if currentX + displayWidth > rect.maxX {
                break
            }
            
            let rootRect = NSRect(x: currentX, y: y, width: displayWidth, height: lineHeight)
            drawText(root, in: rootRect, fontSize: primaryGroupFontSize,
                    color: NSColor.labelColor.withAlphaComponent(0.9), alignment: .left)
            
            currentX += displayWidth + spacing
        }
    }

    // 绘制 primaryGroup 第二行（全宽，左对齐）
    private func drawPrimaryGroupRow2(_ row2Elements: [String], in rect: NSRect) {
        guard !row2Elements.isEmpty else { return }
        
        let font = NSFont.wubiRootFont(size: primaryGroupFontSize)
        let lineHeight = font.ascender - font.descender
        var currentX = rect.minX
        let y = rect.minY + (rect.height - lineHeight) / 2
        let spacing: CGFloat = 3
        
        for root in row2Elements {
            let displayWidth: CGFloat
            if let config = root.parsePartialDisplay() {
                let fullSize = config.character.size(withAttributes: [.font: font])
                displayWidth = fullSize.width * (config.xEnd - config.xStart)
            } else {
                displayWidth = root.size(withAttributes: [.font: font]).width
            }
            
            if currentX + displayWidth > rect.maxX && currentX > rect.minX {
                break
            }
            
            let rootRect = NSRect(x: currentX, y: y, width: displayWidth, height: lineHeight)
            drawText(root, in: rootRect, fontSize: primaryGroupFontSize,
                    color: NSColor.labelColor.withAlphaComponent(0.9), alignment: .left)
            
            currentX += displayWidth + spacing
        }
    }

    // 绘制 secondaryRoots（全宽，支持多行）- 使用新的绘制方法
    private func drawSecondaryRoots(_ secondaryRoots: [String], in rect: NSRect) {
        guard !secondaryRoots.isEmpty else { return }
        
        let font = NSFont.wubiRootFont(size: secondaryRootFontSize)
        let lineHeight = font.ascender - font.descender + 1.5
        var currentY = rect.maxY + 10
        var currentX = rect.minX
        
        for root in secondaryRoots {
            let isWrapped = root.isWrappedWithDash
            let displayText = isWrapped ? root.unwrappedDash : root
            
            let displayWidth: CGFloat
            let boxPadding: CGFloat = 2
            
            if let config = displayText.parsePartialDisplay() {
                let fullSize = config.character.size(withAttributes: [.font: font])
                let partialWidth = fullSize.width * (config.xEnd - config.xStart)
                displayWidth = isWrapped ? partialWidth + boxPadding * 2 : partialWidth
            } else {
                let size = displayText.size(withAttributes: [.font: font])
                displayWidth = isWrapped ? size.width + boxPadding * 2 : size.width
            }
            
            if currentX > rect.minX && currentX + displayWidth > rect.maxX {
                currentX = rect.minX
                currentY -= lineHeight
            }
            
            if currentX == rect.minX && root == secondaryRoots.first {
                currentY -= lineHeight
            }
            
            if currentY < rect.minY { break }
            
            if isWrapped {
                let boxRect = NSRect(x: currentX, y: currentY,
                                    width: displayWidth, height: lineHeight)
                let boxPath = NSBezierPath(roundedRect: boxRect, xRadius: 2, yRadius: 2)
                NSColor.labelColor.withAlphaComponent(0.25).setStroke()
                boxPath.lineWidth = 0.8
                boxPath.stroke()
                
                let textRect = NSRect(x: currentX + boxPadding, y: currentY + 1,
                                     width: displayWidth - boxPadding * 2, height: lineHeight)
                drawText(displayText, in: textRect, fontSize: secondaryRootFontSize,
                        color: NSColor.secondaryLabelColor.withAlphaComponent(0.85), alignment: .left)
                
                currentX += displayWidth + 2.5
            } else {
                let textRect = NSRect(x: currentX, y: currentY, width: displayWidth, height: lineHeight)
                drawText(displayText, in: textRect, fontSize: secondaryRootFontSize,
                        color: NSColor.secondaryLabelColor.withAlphaComponent(0.85), alignment: .left)
                currentX += displayWidth + 2.5
            }
        }
    }


    //
    ///
    ///
    ///
    ///
    
    private func drawKeyLabel(_ label: String, in rect: NSRect) {
        let font = NSFont.systemFont(ofSize: keyLabelFontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.75)
        ]
        let size = label.size(withAttributes: attrs)
        let point = NSPoint(x: rect.minX + 4, y: rect.maxY - size.height - 2)
        label.draw(at: point, withAttributes: attrs)
    }
    
    @discardableResult
    private func drawKeyCode(_ code: Int, in rect: NSRect) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: keyCodeFontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.tertiaryLabelColor
        ]
        let text = String(code)
        let size = text.size(withAttributes: attrs)
        let point = NSPoint(x: rect.maxX - size.width - 4, y: rect.maxY - size.height - 2)
        text.draw(at: point, withAttributes: attrs)
        return size.width + 4  // 返回区位码占用的宽度（包括右边距）
    }
    
    // 绘制右上角重点字根
    // 如果被 "-" 包裹，则直接显示不加圆圈
    // 否则显示圆圈
    private func drawHighlightRoot(_ root: String, in rect: NSRect, afterKeyCodeWidth: CGFloat) {
        let isWrapped = root.isWrappedWithDash
        let displayText = isWrapped ? root.unwrappedDash : root
        
        if isWrapped {
            // 直接显示，不加圆圈
            let font = NSFont.wubiRootFont(size: highlightRootSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)
            ]
            let size = displayText.size(withAttributes: attrs)
            
            // 位置：keyCode 左侧
            let padding: CGFloat = 2
            let textX = rect.maxX - padding - size.width
            let textY = rect.maxY - 1 - size.height
            
            displayText.draw(at: NSPoint(x: textX, y: textY), withAttributes: attrs)
        } else {
            // 显示圆圈
            let circleSize: CGFloat = 16  // 圆圈直径
            let padding: CGFloat = 2      // 与 keyCode 之间的间距
            
            // 圆圈位置（keyCode 左侧）
            let circleX = rect.maxX - padding - circleSize
            let circleY = rect.maxY - 1 - circleSize
            let circleRect = NSRect(x: circleX, y: circleY, width: circleSize, height: circleSize)
            
            // 绘制圆圈
            let circlePath = NSBezierPath(ovalIn: circleRect)
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            circlePath.fill()
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            circlePath.lineWidth = 0.8
            circlePath.stroke()
            
            // 绘制字根（居中）
            let font = NSFont.wubiRootFont(size: highlightRootSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85)
            ]
            let size = displayText.size(withAttributes: attrs)
            let point = NSPoint(
                x: circleRect.midX - size.width / 2,
                y: circleRect.midY - size.height / 2
            )
            displayText.draw(at: point, withAttributes: attrs)
        }
    }
    
    private func drawMainRoot(_ root: String, in rect: NSRect) {
        guard !root.isEmpty && root != " " else { return }
        
        // 主字根区域：左侧 30%
        let mainRootArea = rect.width * 0.30
        let maxW = mainRootArea * 0.95
        let maxH = rect.height * 0.75
        
        var fontSize = baseMainRootSize
        var font = NSFont.wubiRootFont(size: fontSize)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.92)
        ]
        var size = root.size(withAttributes: attrs)
        
        // 动态缩放
        while (size.width > maxW || size.height > maxH) && fontSize > 14 {
            fontSize -= 0.5
            font = NSFont.wubiRootFont(size: fontSize)
            attrs[.font] = font
            size = root.size(withAttributes: attrs)
        }
        
        // 居中定位
        let x = rect.minX + (mainRootArea - size.width) / 2
        let y = rect.maxY - 36
        
        root.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
    }
    
    // 绘制分组字根（优化版：主组避开右上角，次要字根使用更宽区域）
    private func drawRootGroups(primaryGroup: [String], secondaryRoots: [String], in rect: NSRect) {
        // 右侧区域：70%，留出左侧主字根空间
        let leftMargin = rect.width * 0.32
        let rightMargin: CGFloat = 4
        let topMargin: CGFloat = 25  // 给重点字根圆圈和区位码留空间
        let bottomMargin: CGFloat = 3
        
        // 完整内容区域（用于次要字根）
        let fullContentRect = NSRect(
            x: rect.minX + leftMargin,
            y: rect.minY + bottomMargin,
            width: rect.width - leftMargin - rightMargin,
            height: rect.height - topMargin - bottomMargin
        )
        
        // 预留右上角空间：圆圈(15) + padding(2) + 区位码(~20) ≈ 40
        let highlightRootReservedWidth: CGFloat = 2
        
        // 主组字根使用缩小后的区域（避开右上角）
        let primaryContentRect = NSRect(
            x: fullContentRect.minX,
            y: fullContentRect.minY,
            width: fullContentRect.width - highlightRootReservedWidth,
            height: fullContentRect.height
        )
        
        var currentY = fullContentRect.maxY
        
        // 1. 绘制主组（第一行，使用缩小的区域避开右上角）
        if !primaryGroup.isEmpty {
            let primaryFont = NSFont.wubiRootFont(size: primaryGroupFontSize)
            let primaryAttrs: [NSAttributedString.Key: Any] = [
                .font: primaryFont,
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.9)
            ]
            
            let lineHeight = primaryFont.ascender - primaryFont.descender + 2
            currentY -= lineHeight
            
            var currentX = primaryContentRect.minX  // 使用缩小后的起点
            for root in primaryGroup {
                let size = root.size(withAttributes: primaryAttrs)
                
                // 换行判断 - 使用缩小后的最大X坐标
                if currentX + size.width > primaryContentRect.maxX && currentX > primaryContentRect.minX {
                    currentX = primaryContentRect.minX
                    currentY -= lineHeight
                }
                
                if currentY < primaryContentRect.minY { break }
                
                root.draw(at: NSPoint(x: currentX, y: currentY), withAttributes: primaryAttrs)
                currentX += size.width + 3
            }
            
            currentY -= 2  // 主组和次要字根之间的间距
        }
        
        // 2. 绘制次要字根（使用完整宽度区域，更宽）
        if !secondaryRoots.isEmpty {
            let secondaryFont = NSFont.wubiRootFont(size: secondaryRootFontSize)
            let secondaryAttrs: [NSAttributedString.Key: Any] = [
                .font: secondaryFont,
                .foregroundColor: NSColor.secondaryLabelColor.withAlphaComponent(0.85)
            ]
            
            let lineHeight = secondaryFont.ascender - secondaryFont.descender + 1.5
            currentY -= lineHeight
            
            var currentX = fullContentRect.minX  // 使用完整区域起点，更宽
            for root in secondaryRoots {
                let isWrapped = root.isWrappedWithDash
                let displayText = isWrapped ? root.unwrappedDash : root
                let size = displayText.size(withAttributes: secondaryAttrs)
                
                // 如果需要矩形边框，计算边框大小
                let boxPadding: CGFloat = 2
                let boxWidth = isWrapped ? size.width + boxPadding * 2 : size.width
                
                // 换行判断 - 使用完整区域的最大X坐标
                if currentX + boxWidth > fullContentRect.maxX && currentX > fullContentRect.minX {
                    currentX = fullContentRect.minX
                    currentY -= lineHeight
                }
                
                if currentY < fullContentRect.minY { break }
                
                if isWrapped {
                    // 绘制圆角矩形边框
                    let boxRect = NSRect(
                        x: currentX,
                        y: currentY - 1,
                        width: boxWidth,
                        height: size.height + 2
                    )
                    let boxPath = NSBezierPath(roundedRect: boxRect, xRadius: 2, yRadius: 2)
                    NSColor.labelColor.withAlphaComponent(0.25).setStroke()
                    boxPath.lineWidth = 0.8
                    boxPath.stroke()
                    
                    // 绘制文字（居中于矩形框内）
                    let textPoint = NSPoint(x: currentX + boxPadding, y: currentY)
                    displayText.draw(at: textPoint, withAttributes: secondaryAttrs)
                    
                    currentX += boxWidth + 2.5
                } else {
                    // 正常绘制
                    displayText.draw(at: NSPoint(x: currentX, y: currentY), withAttributes: secondaryAttrs)
                    currentX += size.width + 2.5
                }
            }
        }
    }

}

// MARK: - 4. 数据工厂 (新世纪五笔标准版)

struct WubiDataFactory {
    static func getXinShiJiData() -> [[WubiKeyData]] {
        return [
            // 第一行 (Q-P) 撇区 & 捺区
            [
                .init(key: "Q", mainRoot: "金", highlightRoot: "-勹-",
                      primaryGroup: ["钅", "+卬+0.01+0.5+0.01+0.99+"],
                      secondaryRoots: ["夕", "+然+0.01+0.5+0.27+0.99+[0.33,0.26,0.16,0.139]+", "+夕+0.0+1.0+0.0+0.99+[0.39,0.385,0.162,0.09]+", "+万+0.0+1.0+0.0+0.99+[0.0,0.567,0.999,0.19]+", "⺈", "+鱼+0.0+1.0+0.27+0.99+", "儿","+尤+0.0+1.0+0.0+0.99+[0.0,0.45,0.41,0.19]+[0.5,0.46,0.42,0.19]+", "-犭-"],
                      keyCode: 35, zone: 3),
                
                .init(key: "W", mainRoot: "人", highlightRoot: "-八-",
                      primaryGroup: [],
                      secondaryRoots: ["几", "+风+0.0+1.0+0.0+1.0+[0.27,0.1,0.4,0.48]+", "       ", "癶", "亻","           ", "+祭+0.0+1.0+0.0+1.0+[0.2,0.1,0.6,0.20]+[0.28,0.3,0.41,0.10]+[0.38,0.4,0.2,0.10]+"],
                      keyCode: 34, zone: 3),
                
                .init(key: "E", mainRoot: "月", highlightRoot: "彡",
                      primaryGroup: ["+肌+0.01+0.41+0.01+0.99+", "+舟+0.0+1.0+0.0+0.625+"],
                      secondaryRoots: ["爫", "力", "豸", "+豕+0.0+1.0+0.0+0.625+", "+衣+0.0+1.0+0.0+0.53+", "+派+0.46+1.0+0.0+0.63+[0.46,0.50,0.16,0.13]+", "+衣+0.355+1.0+0.0+0.5+",  "+舆+0.0+1.0+0.366+1.0+[0.42,0.366,0.22,0.45]+[0.82,0.366,0.16,0.1]+", "臼"],
                      keyCode: 33, zone: 3),
                
                // === 示例1：显示"歆"字的右半部分（音部）===
                .init(key: "R", mainRoot: "白", highlightRoot: "+彳+0.0+1.0+0.333+0.99+[0.48,0.333,0.52,0.09]+",  // 显示右半部分
                      primaryGroup: ["+斤+0.0+1.0+0.0+1.0+[0.37,0.1,0.5,0.48]+"],
                      secondaryRoots: ["斤", "+兵+0.0+1.0+0.39+1.0+[0.65,0.39,0.25,0.08]+", "+⺧+0.0+1.0+0.0+0.99+[0.45,0.56,0.16,0.19]+[0.476,0.43,0.16,0.1]+", "㐅", "扌", "+看+0.0+1.0+0.0+1.0+[0.38,0.05,0.02,0.33]+[0.40,0.05,0.5,0.36]+[0.41,0.41,0.5,0.05]+", "手"],
                      keyCode: 32, zone: 3),
                
                .init(key: "T", mainRoot: "禾", highlightRoot: "丿",
                      primaryGroup: ["+⺧+0.0+1.0+0.0+0.99+[0.45,0.56,0.16,0.19]+[0.35,0.41,0.63,0.1]+[0.0,0.23,0.99,0.18]+"],
                      secondaryRoots: ["⺮", "     ", "夂", "攵", "+牝+0.0+0.5+0.0+0.9+", "       ", "彳"],
                      keyCode: 31, zone: 3),
                
                .init(key: "Y", mainRoot: "言", highlightRoot: "丶",
                      primaryGroup: ["讠", "㇏"],
                      secondaryRoots: ["文", "        ", "亠", "方", "        ", "+隹+0.38+1.0+0.0+0.99+[0.38,0.56,0.06,0.19]+"],
                      keyCode: 41, zone: 4),
                
                .init(key: "U", mainRoot: "立", highlightRoot: "冫",
                      primaryGroup: [],
                      secondaryRoots: ["+兰+0.0+1.0+0.47+1.0+", "+兰+0.0+1.0+0.56+0.99+", "丬", "+永+0.6+1.0+0.0+1.0+","  ", "疒", "    ", "+北+0.01+0.5+0.01+0.99+", "  ", "门"],
                      keyCode: 42, zone: 4),
                
                // === 示例2：primaryGroup 中使用局部显示 ===
                .init(key: "I", mainRoot: "水", highlightRoot: "氵",
                      primaryGroup: [],  // 显示"永"字的右半部分
                      secondaryRoots: ["氺", "⺗"],
                      keyCode: 43, zone: 4),
                
                .init(key: "O", mainRoot: "火", highlightRoot: "-灬-",
                      primaryGroup: [],
                      secondaryRoots: ["+亦+0.0+1.0+0.0+0.99+[0.0,0.521,0.999,0.239]+", "+业+0.0+1.0+0.0+0.99+[0.0,0.067,0.999,0.23]+", "+亦+0.0+1.0+0.0+0.99+[0.0,0.521,0.999,0.239]+[0.0,0.067,0.999,0.19]+","   ", "广","    ", "+鬯+0.0+1.0+0.0+0.99+[0.0,0.00,0.999,0.42]+[0.0,0.42,0.263,0.239]+[0.60,0.42,0.12,0.09]+[0.73,0.42,0.2,0.239]+", "米"],
                      keyCode: 44, zone: 4),
                
                .init(key: "P", mainRoot: "之", highlightRoot: "-宀-",
                      primaryGroup: [],
                      secondaryRoots: ["辶", "         ", "冖", "廴","   ", "-衤-", "-礻-"],
                      keyCode: 45, zone: 4)
            ],
            
            // 第二行 (A-L) 横区 & 竖区
            [
                .init(key: "A", mainRoot: "工", highlightRoot: "-匚-",
                      primaryGroup: ["     ", "+旡+0.0+1.0+0.0+0.99+[0.3,0.5,0.5,0.135]+[0.0,0.067,0.999,0.35]+[0.3,0.417,0.5,0.03]+"],
                      secondaryRoots: ["戈", "+弋+0.2+1.0+0.0+1.0+[0.58,0.6,0.2,0.2]+", "+切+0.0+0.45+0.0+1.0+[0.3,0.05,0.08,0.07]+[0.308,0.05,0.142,0.23]+", "+车+0.0+1.0+0.0+0.99+[0.48,0.48,0.4,0.1]+[0.0,0.067,0.999,0.34]+[0.48,0.407,0.1,0.03]+", "七", "艹", "廾", "+昔+0.2+1.0+0.0+1.0+[0.2,0.0,0.7,0.41]+", "+廿+0.1+0.9+0.0+1.0+", "+冓+0.2+0.87+0.0+1.0+[0.2,0.0,0.67,0.47]+"],
                      keyCode: 15, zone: 1),
                
                .init(key: "S", mainRoot: "木", highlightRoot: "-丁-",
                      primaryGroup: [],
                      secondaryRoots: ["                  ", "西", "覀"],  // 示例：西字加矩形边框
                      keyCode: 14, zone: 1),
                
                .init(key: "D", mainRoot: "大", highlightRoot: "三",
                      primaryGroup: [],
                      secondaryRoots: ["古", "          ", "镸", "石", "+百+0.0+1.0+0.0+0.99+[0.0,0.067,0.5,0.418]+[0.5,0.106,0.3,0.45]+", "𠂇", "厂"],
                      keyCode: 13, zone: 1),
                
                .init(key: "F", mainRoot: "土", highlightRoot: "二",
                      primaryGroup: ["士"],
                      secondaryRoots: ["干", "        ", "寸", "十", "+寸+0.0+1.0+0.0+0.99+[0.3,0.306,0.23,0.16]+", "   ", "雨"],
                      keyCode: 12, zone: 1),
                
                .init(key: "G", mainRoot: "王", highlightRoot: "一",
                      primaryGroup: [],
                      secondaryRoots: ["龶","           ", "㇀", "五", "      ", "+夫+0.0+1.0+0.0+1.0+[0.5,0.1,0.5,0.28]+", "+牛+0.0+1.0+0.0+1.0+[0.1,0.46,0.25,0.36]+[0.35,0.57,0.1,0.3]+"],
                      keyCode: 11, zone: 1),
                
                .init(key: "H", mainRoot: "目", highlightRoot: "丨",
                      primaryGroup: ["+具+0.0+1.0+0.0+0.99+[0.0,0.067,0.999,0.22]+"],
                      secondaryRoots: ["止", "+走+0.0+1.0+0.0+0.42+[0.0,0.39,0.46,0.03]+", "+步+0.0+1.0+0.0+0.46+[0.0,0.44,0.36,0.02]+", "+上+0.0+1.0+0.29+0.99+", "卜", "+虍+0.0+1.0+0.0+1.0+[0.35,0.1,0.32,0.416]+[0.67,0.1,0.3,0.376]+", "+皮+0.0+1.0+0.0+1.0+[0.32,0.1,0.68,0.368]+"],
                      keyCode: 21, zone: 2),
                
                .init(key: "J", mainRoot: "日", highlightRoot: "+卝+0.0+0.67+0.0+1.0+[0.0,0.30,0.38,0.23]+",//"+卝+0.0+1.0+0.333+0.99+[0.48,0.333,0.52,0.09]+",
                      primaryGroup: [],
                      secondaryRoots: ["         ", "+归+0.01+0.46+0.01+0.99+", "+川+0.01+0.66+0.01+0.99+", "刂", "曰", "+冒+0.0+1.0+0.0+0.99+[0.0,0.067,0.999,0.386]+", "     ", "虫"],  // 示例：刂字加矩形边框
                      keyCode: 22, zone: 2),
                
                .init(key: "K", mainRoot: "口", highlightRoot: "川",//顺
                      primaryGroup: [],
                      secondaryRoots: ["                  ","川", "           ", "+㐬+0.0+1.0+0.0+0.99+[0.0,0.4,0.999,0.369]+"],
                      keyCode: 23, zone: 2),
                
                // === 示例4：secondaryRoots 中使用局部显示 ===//"皿",
                .init(key: "L", mainRoot: "田", highlightRoot:  "!+卌+0.0+0.749+0.0+1.0+[0.0,0.39,0.23,0.16]+[0.31,0.39,0.0593,0.16]+[0.433,0.39,0.089,0.16]+[0.602,0.39,0.0602,0.16]+",
                      primaryGroup: ["囗"],
                      secondaryRoots: ["甲", "+单+0.0+1.0+0.0+0.62+", "车", "   ", "四", "罒", "皿", "+曾+0.0+1.0+0.0+0.99+[0.0,0.63,0.999,0.239]+[0.0,0.067,0.999,0.339]+"],  // 显示"单"字的下半部分
                      keyCode: 24, zone: 2)
            ],
            
            // 第三行 (Z-M) 折区
            [
                .init(key: "Z", mainRoot: "", highlightRoot: "",
                      primaryGroup: [],
                      secondaryRoots: ["  学习键"],
                      keyCode: 0, zone: 0),
                
                .init(key: "X", mainRoot: "幺", highlightRoot: "-母-",
                      primaryGroup: ["+纟+0.0+1.0+0.32+0.99+", "纟"],
                      secondaryRoots: ["+互+0.0+1.0+0.275+0.61+[0.69,0.275,0.31,0.03]+", "    ", "弓", "  ",  "+我+0.46+1.0+0.01+0.99+[0.46,0.36,0.083,0.14]+[0.46,0.5,0.063,0.1]+[0.46,0.6,0.049,0.1]+[0.618,0.50,0.289,0.12]+[0.633,0.62,0.289,0.12]+", "          ", "+比+0.01+0.5+0.01+0.99+", "   ", "匕"],
                      keyCode: 55, zone: 5),
                
                .init(key: "C", mainRoot: "又", highlightRoot: "-厶-",
                      primaryGroup: ["瓜"],
                      secondaryRoots: ["+龴+0.0+1.0+0.0+0.99+[0.0,0.067,0.999,0.35]+", "ス", "        ", "巴", "           ", "+马+0.0+1.0+0.0+1.0+[0.0,0.27,0.68,0.1]+"],
                      keyCode: 54, zone: 5),
                
                .init(key: "V", mainRoot: "女", highlightRoot: "巛",
                      primaryGroup: [],
                      secondaryRoots: ["刀", "          ", "九", "彐", "+录+0.0+1.0+0.5+0.9+", "+君+0.0+1.0+0.399+0.9+[0.3,0.45,0.2,0.07]+[0.4,0.57,0.2,0.06]+"],
                      keyCode: 53, zone: 5),
                
                .init(key: "B", mainRoot: "子", highlightRoot: "巜",
                      primaryGroup: ["+孩+0.0+0.45+0.0+1.0+[0.36,0.05,0.1,0.33]+", "了"],
                      secondaryRoots: ["阝", "耳", "卩", "+氾+0.4+1.0+0.0+1.0+", " ", "也", "乃", "     ", "+山+0.0+1.0+0.0+1.0+[0.37,0.3,0.2,0.5]+"],
                      keyCode: 52, zone: 5),
                
                .init(key: "N", mainRoot: "已", highlightRoot: "乙",
                      primaryGroup: ["+祀+0.45+1.0+0.0+1.0+"," ", "+改+0.0+0.45+0.0+1.0+[0.35,0.05,0.1,0.33]+"],
                      secondaryRoots: ["+彐+0.0+1.0+0.0+1.0+[0.0,0.37,0.65,0.1]+", "+录+0.0+1.0+0.5+0.9+[0.0,0.57,0.65,0.08]+", "+眉+0.0+1.0+0.0+1.0+[0.35,0.05,0.03,0.33]+[0.38,0.05,0.5,0.36]+[0.35,0.41,0.5,0.12]+", "尸", "心", "忄", "⺗", "羽"],
                      keyCode: 51, zone: 5),
                
                .init(key: "M", mainRoot: "山", highlightRoot: "-由-",
                      primaryGroup: [],
                      secondaryRoots: ["贝", "+骨+0.0+1.0+0.0+1.0+[0.3,0.1,0.4,0.4]+","        ", "冂", "+周+0.0+1.0+0.0+1.0+[0.3,0.27,0.41,0.39]+"],
                      keyCode: 25, zone: 2)
            ]
        ]
    }
}

// MARK: - 5. SwiftUI 预览包装器

struct WubiLayoutPreview: NSViewRepresentable {
    func makeNSView(context: Context) -> WubiKeyboardLayoutView {
        return WubiKeyboardLayoutView(frame: .zero)
    }
    
    func updateNSView(_ nsView: WubiKeyboardLayoutView, context: Context) {
        nsView.needsDisplay = true
    }
}

// MARK: - 6. Xcode Canvas 入口

#Preview("新世纪五笔标准尺寸") {
    ZStack {
        // 模拟桌面背景
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
        
        VStack(spacing: 20) {
            Text("新世纪五笔字根悬浮窗（支持局部显示）")
                .font(.headline)
                .foregroundStyle(.secondary)
            
            Text("✅ 已修复：局部显示字符不再重复 | 差集语法：+字+x1+x2+y1+y2+[mx,my,mw,mh]+")
                .font(.caption)
                .foregroundStyle(.tertiary)
            
            WubiLayoutPreview()
                .frame(width: 820, height: 280) // 目标尺寸
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 5)
        }
        .padding()
    }
}

// MARK: - MenuBarStatusController (SwiftUI 实现)
// 在 SquirrelPanel.swift 文件尾部添加

final class MenuBarStatusController: ObservableObject {
    // MARK: - 状态
    @Published var currentSchema: InputSchemaType = .other
    @Published var currentSchemaId: String = ""  // ✅ 保存实际的 schema_id
  
    @Published var availableSchemas: [(id: String, name: String)] = []  // ✅ 从配置读取
    @Published var isInputMethodActive: Bool = false  // ✅ 新增：输入法激活状态
    
    private var statusItem: NSStatusItem!
    private var hostingView: NSHostingView<MenuBarStatusView>?
    private let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee
    // ✅ 新增：防抖定时器
    private var updateTimer: Timer?
    private let updateDelay: TimeInterval = 0.05  // 50ms 防抖
    private var hasLoadedSchemas = false  // ✅ 添加标志位
    
    // MARK: - 输入方案枚举（简化为显示用）
    enum InputSchemaType {
        case wubi
        case doublePinyin
        case pinyin
        case other
        
        var displayText: String {
            switch self {
            case .wubi: return "五"
            case .doublePinyin: return "双"
            case .pinyin: return "拼"
            case .other: return "拼"
            }
        }
        
        static func from(schemaId: String) -> Self {
            if schemaId.contains("wubi") {
                return .wubi
            } else if schemaId.contains("double_pinyin") || schemaId.contains("flypy") {
                return .doublePinyin
            } else if schemaId.contains("pinyin") || schemaId.contains("rime_ice") {
                return .pinyin
            } else {
                return .other
            }
        }
        
        // ✅ 根据具体 schema_id 返回更精确的显示
        static func detailedDisplay(for schemaId: String) -> String {
            if schemaId.contains("flypy") {
                return "鹤"
            } else if schemaId.contains("mspy") {
                return "微"
            } else if schemaId == "double_pinyin" {
                return "自"
            } else if schemaId.contains("wubi06") {
                return "五"
            } else if schemaId.contains("rime_ice") {
                return "雾"
            } else {
                return from(schemaId: schemaId).displayText
            }
        }
    }
    
    // MARK: - 初始化
    init() {
        setupStatusItem()
        observeNotifications()
      // ⚠️ 移除这行：不再在初始化时加载
    }
    
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        let contentView = MenuBarStatusView(controller: self)
        hostingView = NSHostingView(rootView: contentView)
        
        if let button = statusItem.button {
            // 移除默认的标题
            button.title = ""
            button.image = nil
            
            // 设置自定义视图
            button.subviews.forEach { $0.removeFromSuperview() }
            if let hostingView = hostingView {
                hostingView.frame = CGRect(x: 0, y: 0, width: 30, height: 22)
                button.addSubview(hostingView)
                
                // 添加约束确保视图居中
                hostingView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    hostingView.centerXAnchor.constraint(equalTo: button.centerXAnchor),
                    hostingView.centerYAnchor.constraint(equalTo: button.centerYAnchor),
                    hostingView.widthAnchor.constraint(equalToConstant: 30),
                    hostingView.heightAnchor.constraint(equalToConstant: 22)
                ])
            }
            
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
    }
    
    // ✅ 使用 Rime API 读取可用方案（更稳定）
    private func loadAvailableSchemas() {
        var schemas: [(id: String, name: String)] = []
        
        // 创建一个临时的 RimeConfig 来读取配置
        var config = RimeConfig()
        guard rimeAPI.config_open("default", &config) else {
            NSLog("⚠️ 无法打开 default 配置，使用默认方案列表")
            self.availableSchemas = [
                (id: "rime_ice", name: "雾凇拼音"),
                (id: "double_pinyin_flypy", name: "小鹤双拼"),
                (id: "double_pinyin", name: "自然码双拼"),
                (id: "double_pinyin_mspy", name: "微软双拼"),
                (id: "wubi06", name: "五笔06")
            ]
            return
        }
        
        defer { _ = rimeAPI.config_close(&config) }
        
        var iterator = RimeConfigIterator()
        
        // 读取 schema_list
        if rimeAPI.config_begin_list(&iterator, &config, "schema_list") {
            while rimeAPI.config_next(&iterator) {
                // 读取 schema id
                if let path = iterator.path {
                    let pathStr = String(cString: path)
                    let schemaKey = "\(pathStr)/schema"
                    
                    if let schemaIdPtr = rimeAPI.config_get_cstring(&config, schemaKey) {
                        let schemaId = String(cString: schemaIdPtr)
                        
                        // 尝试打开 schema 配置获取名称
                        var schemaConfig = RimeConfig()
                        var schemaName = schemaId  // 默认使用 id 作为名称
                        
                        if rimeAPI.schema_open(schemaId, &schemaConfig) {
                            if let namePtr = rimeAPI.config_get_cstring(&schemaConfig, "schema/name") {
                                schemaName = String(cString: namePtr)
                            }
                            _ = rimeAPI.config_close(&schemaConfig)
                        }
                        
                        schemas.append((id: schemaId, name: schemaName))
                        NSLog("✅ 读取方案: \(schemaId) - \(schemaName)")
                    }
                }
            }
            rimeAPI.config_end(&iterator)
        }
        
        self.availableSchemas = schemas
        NSLog("📋 共加载 \(schemas.count) 个输入方案")
    }
    
    // MARK: - 状态更新 - 防抖
    func update(schemaId: String) {
        // 取消之前的定时器
        updateTimer?.invalidate()
        
        // 设置新的定时器（防抖）
        updateTimer = Timer.scheduledTimer(withTimeInterval: updateDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                self.currentSchemaId = schemaId
                self.currentSchema = InputSchemaType.from(schemaId: schemaId)
            }
        }
    }
    
    // ✅ 新增：更新激活状态
    func updateActiveState(isActive: Bool) {
        DispatchQueue.main.async {
            self.isInputMethodActive = isActive
        }
    }
    
    // MARK: - 事件处理
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        // ✅ 失活状态下点击无反应
        guard isInputMethodActive else { return }
        showMenu()
    }
    
    private func showMenu() {
        // ✅ 失活状态下不显示菜单
        guard isInputMethodActive else { return }
        
        // ✅ 懒加载：首次点击时才加载方案列表
        if !hasLoadedSchemas {
            hasLoadedSchemas = true
            loadAvailableSchemas()
        }

        let menu = NSMenu()
        
        
        // ✅ 2. 备选输入方案（从配置读取）
        if !availableSchemas.isEmpty {
            for schema in availableSchemas {
                let schemeItem = NSMenuItem(
                    title: schema.name,
                    action: #selector(switchToScheme(_:)),
                    keyEquivalent: ""
                )
                schemeItem.target = self
                schemeItem.representedObject = schema.id
                
                // 当前方案打勾
                if schema.id == currentSchemaId {
                    schemeItem.state = .on
                }
                
                menu.addItem(schemeItem)
            }
        }
        
        self.statusItem.menu = menu
        self.statusItem.button?.performClick(nil)
        self.statusItem.menu = nil
    }
  
    // MARK: - 菜单动作
    // ✅ 切换输入方案
    @objc private func switchToScheme(_ sender: NSMenuItem) {
        guard let schemaId = sender.representedObject as? String else { return }
        
        // 发送方案切换命令给 Rime
        NotificationCenter.default.post(
            name: .squirrelSwitchSchema,
            object: nil,
            userInfo: ["schemaId": schemaId]
        )
    }
    
    // MARK: - 通知监听
    private func observeNotifications() {
        // 状态变化通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInputStateChange(_:)),
            name: .squirrelInputStateChanged,
            object: nil
        )
        
        // ✅ 激活/失活通知
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInputMethodActivated),
            name: .squirrelInputMethodActivated,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInputMethodDeactivated),
            name: .squirrelInputMethodDeactivated,
            object: nil
        )
    }
    
    // ✅ 优化：处理状态变化通知
    @objc private func handleInputStateChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let schemaId = userInfo["schemaId"] as? String else {
            return
        }
        
        update(schemaId: schemaId)
    }
    
    // ✅ 优化：激活处理（不再重复处理）
    @objc private func handleInputMethodActivated() {
        updateActiveState(isActive: true)
    }
    
    // ✅ 优化：失活处理
    @objc private func handleInputMethodDeactivated() {
        updateActiveState(isActive: false)
    }
}

// MARK: - SwiftUI 视图
private struct MenuBarStatusView: View {
    @ObservedObject var controller: MenuBarStatusController
    
    var body: some View {
        Text(displayText)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.primary)
            .padding(.horizontal, 4)
            .frame(height: 22)
    }
    
    // ✅ 根据激活状态显示不同内容
    private var displayText: String {
        if !controller.isInputMethodActive {
            return "···"  // 失活时显示三个点
        }
        return MenuBarStatusController.InputSchemaType.detailedDisplay(
            for: controller.currentSchemaId
        )
    }
}

// MARK: - Notification 扩展
extension Notification.Name {
    static let squirrelInputStateChanged = Notification.Name("SquirrelInputStateChanged")
    static let squirrelSwitchSchema = Notification.Name("SquirrelSwitchSchema")
    static let squirrelInputMethodActivated = Notification.Name("SquirrelInputMethodActivated")
    static let squirrelInputMethodDeactivated = Notification.Name("SquirrelInputMethodDeactivated")
}
