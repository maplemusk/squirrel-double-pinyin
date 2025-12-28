//
//  SquirrelPanel.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//  Modified: 独立双拼提示窗 + 键盘UI + 智能双拼检测
//

import AppKit

// MARK: - SquirrelPanel (主面板)

final class SquirrelPanel: NSPanel {
  private let view: SquirrelView
  private let back: NSVisualEffectView
  private var currentSchemaId: String = ""  // ✅ 新增
  // ✅ 独立的悬浮窗口
  private var hintWindow: DoublePinyinHintWindow?
  
  var inputController: SquirrelInputController?

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
      } else if event.phase == .ended || (event.phase == .init(rawValue: 0) && event.momentumPhase != .init(rawValue: 0)) {
        if abs(scrollDirection.dx) > abs(scrollDirection.dy) && abs(scrollDirection.dx) > 10 {
          _ = inputController?.page(up: (scrollDirection.dx < 0) == vertical)
        } else if abs(scrollDirection.dx) < abs(scrollDirection.dy) && abs(scrollDirection.dy) > 10 {
          _ = inputController?.page(up: scrollDirection.dy > 0)
        }
        scrollDirection = .zero
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
  }

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
      if let schemaId = inputController?.schemaId, schemaId != currentSchemaId {
        currentSchemaId = schemaId
        hintWindow?.updateScheme(from: schemaId)  // 🔥 自动推断键位方案
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
          String(labels.first![labels.first!.index(labels.first!.startIndex, offsetBy: i)])
        } else {
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
  func updateDoublePinyinHint() {
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
  
  // ✅ 加载配置
  func loadDoublePinyinHintConfig(config: SquirrelConfig) {
    let enabled = config.getBool("double_pinyin_hints/enabled") ?? true
    
    NSLog("⚙️ [Squirrel] Config - enabled: \(enabled)")
    
    hintWindow?.configure(enabled: enabled)
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

  // swiftlint:disable:next cyclomatic_complexity
  func show() {
    currentScreen()
    let theme = view.currentTheme
    if theme.native || view.darkTheme.available {
      self.appearance = NSApp.effectiveAppearance
    } else {
      self.appearance = NSAppearance(named: .aqua)
    }

    let textWidth = maxTextWidth()
    let maxTextHeight = vertical ? screenRect.width - theme.edgeInset.width * 2 : screenRect.height - theme.edgeInset.height * 2
    view.textContainer.size = NSSize(width: textWidth, height: maxTextHeight)

    var panelRect = NSRect.zero
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
      panelRect.size = NSSize(
        width: min(0.95 * screenRect.width, contentRect.height + theme.edgeInset.height * 2),
        height: min(0.95 * screenRect.height, contentRect.width + theme.edgeInset.width * 2) + theme.pagingOffset
      )

      if position.midY / screenRect.height >= 0.5 {
        panelRect.origin.y = position.minY - SquirrelTheme.offsetHeight - panelRect.height + theme.pagingOffset
      } else {
        panelRect.origin.y = position.maxY + SquirrelTheme.offsetHeight
      }
      
      panelRect.origin.x = position.minX - panelRect.width - SquirrelTheme.offsetHeight
      if view.preeditRange.length > 0, let preeditTextRange = view.convert(range: view.preeditRange) {
        let preeditRect = view.contentRect(range: preeditTextRange)
        panelRect.origin.x += preeditRect.height + theme.edgeInset.width
      }
    } else {
      panelRect.size = NSSize(
        width: min(0.95 * screenRect.width, contentRect.width + theme.edgeInset.width * 2),
        height: min(0.95 * screenRect.height, contentRect.height + theme.edgeInset.height * 2)
      )
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
    
    // ✅ 关键调用：每次 UI 刷新时重新检查是否应该显示提示窗
    updateDoublePinyinHint()
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
    
    let initialFrame = NSRect(x: 0, y: 0, width: 580, height: 140)
    
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
    let hintHeight: CGFloat = 139
    
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
        [("Q", "iu"), ("W", "ia"), ("E", "e"), ("R", "uan"), ("T", "ue"), ("Y", "ing"), ("U", "sh·u"), ("I", "ch·i"), ("O", "uo"), ("P", "un")],
        [("A", "a"), ("S", "ong"), ("D", "iang"), ("F", "en"), ("G", "eng"), ("H", "ang"), ("J", "an"), ("K", "ao"), ("L", "ai")],
        [("Z", "ei"), ("X", "ie"), ("C", "iao"), ("V", "zh·ü"), ("B", "ou"), ("N", "in"), ("M", "ian")]
      ]
    ),
    
    "flypy": SchemeLayout(
      name: "小鹤双拼",
      rows: [
        [("Q", "iu"), ("W", "ei"), ("E", "e"), ("R", "uan"), ("T", "ue"), ("Y", "un"), ("U", "sh·u"), ("I", "ch·i"), ("O", "uo"), ("P", "ie")],
        [("A", "a"), ("S", "ong"), ("D", "ai"), ("F", "en"), ("G", "eng"), ("H", "ang"), ("J", "an"), ("K", "ing"), ("L", "iang")],
        [("Z", "ou"), ("X", "ia"), ("C", "ao"), ("V", "zh·ui"), ("B", "in"), ("N", "iao"), ("M", "ian")]
      ]
    ),
    
    "abc": SchemeLayout(
      name: "智能ABC",
      rows: [
        [("Q", "ei"), ("W", "ian"), ("E", "ch·e"), ("R", "iu"), ("T", "iang"), ("Y", "ing"), ("U", "u"), ("I", "i"), ("O", "uo"), ("P", "uan")],
        [("A", "zh·a"), ("S", "ong"), ("D", "ia"), ("F", "en"), ("G", "eng"), ("H", "ang"), ("J", "an"), ("K", "ao"), ("L", "ai")],
        [("Z", "iao"), ("X", "ie"), ("C", "in"), ("V", "sh·ü"), ("B", "ou"), ("N", "un"), ("M", "ui")]
      ]
    ),
    
    "mspy": SchemeLayout(
      name: "微软双拼",
      rows: [
        [("Q", "iu"), ("W", "ia"), ("E", "e"), ("R", "uan"), ("T", "ue"), ("Y", "ing"), ("U", "sh·u"), ("I", "ch·i"), ("O", "uo"), ("P", "un")],
        [("A", "a"), ("S", "ong"), ("D", "iang"), ("F", "en"), ("G", "eng"), ("H", "ang"), ("J", "an"), ("K", "ao"), ("L", "ai"), (";", "ing")],
        [("Z", "ei"), ("X", "ie"), ("C", "iao"), ("V", "zh·ui"), ("B", "ou"), ("N", "in"), ("M", "ian")]
      ]
    ),
    
    "ziguang": SchemeLayout(
      name: "紫光双拼",
      rows: [
        [("Q", "ao"), ("W", "en"), ("E", "e"), ("R", "an"), ("T", "eng"), ("Y", "ing"), ("U", "zh·u"), ("I", "sh·i"), ("O", "uo"), ("P", "ai")],
        [("A", "ch·a"), ("S", "ang"), ("D", "ie"), ("F", "ian"), ("G", "iang"), ("H", "ong"), ("J", "iu"), ("K", "ei"), ("L", "uan"), (";", "ing")],
        [("Z", "ou"), ("X", "ia"), ("B", "iao"), ("N", "ui"), ("M", "un")]
      ]
    ),
    
    // ✅ 新增：搜狗双拼（与微软基本相同）
    "sogou": SchemeLayout(
      name: "搜狗双拼",
      rows: [
        [("Q", "iu"), ("W", "ia"), ("E", "e"), ("R", "uan"), ("T", "ue"), ("Y", "ing"), ("U", "sh·u"), ("I", "ch·i"), ("O", "uo"), ("P", "un")],
        [("A", "a"), ("S", "ong"), ("D", "iang"), ("F", "en"), ("G", "eng"), ("H", "ang"), ("J", "an"), ("K", "ao"), ("L", "ai"), (";", "ing")],
        [("Z", "ei"), ("X", "ie"), ("C", "iao"), ("V", "zh·ui"), ("B", "ou"), ("N", "in"), ("M", "ian")]
      ]
    ),
    
    // ✅ 新增：拼音加加
    "jiajia": SchemeLayout(
      name: "加加双拼",
      rows: [
        [("Q", "er"), ("W", "ia"), ("E", "e"), ("R", "en"), ("T", "eng"), ("Y", "in"), ("U", "sh·u"), ("I", "ch·i"), ("O", "uo"), ("P", "ou")],
        [("A", "a"), ("S", "ang"), ("D", "ao"), ("F", "an"), ("G", "ang"), ("H", "iang"), ("J", "ian"), ("K", "iao"), ("L", "in")],
        [("Z", "un"), ("X", "ue"), ("C", "uan"), ("V", "zh·ü"), ("B", "iong"), ("N", "iu"), ("M", "ie")]
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
    var y = bounds.height - padding - 20
    
    // ✅ 标题
    let titleAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
      .foregroundColor: NSColor.secondaryLabelColor
    ]
    let title = "双拼键位参考 - \(layout.name)"
    let titleSize = title.size(withAttributes: titleAttrs)
    let titleX = (bounds.width - titleSize.width) / 2
    title.draw(at: NSPoint(x: titleX, y: y), withAttributes: titleAttrs)
    
    y -= 32
    
    // ✅ 绘制三行键盘
    for row in layout.rows {
      drawKeyboardRow(row: row, y: y, padding: padding)
      y -= 32
    }
  }
  
  // ✅ 绘制一行键盘（模拟真实键盘样式）
  private func drawKeyboardRow(row: [(letter: String, vowel: String)], y: CGFloat, padding: CGFloat) {
    let keyWidth: CGFloat = 52
    let keyHeight: CGFloat = 28
    let keySpacing: CGFloat = 4
    let rowWidth = CGFloat(row.count) * (keyWidth + keySpacing) - keySpacing
    var x = (bounds.width - rowWidth) / 2
    
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
      
      // ✅ 26字母（左上角，深色小字，提高辨识度）
      let letterAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 9, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor  // 从 tertiary 改为 secondary
      ]
      key.letter.draw(at: NSPoint(x: x + 4, y: y + keyHeight - 13), withAttributes: letterAttrs)
      
      // ✅ 韵母（居中，大字加粗）
      let vowelAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor.labelColor
      ]
      let vowelSize = key.vowel.size(withAttributes: vowelAttrs)
      let vowelX = x + (keyWidth - vowelSize.width) / 2
      let vowelY = y + (keyHeight - vowelSize.height) / 2 - 2
      key.vowel.draw(at: NSPoint(x: vowelX, y: vowelY), withAttributes: vowelAttrs)
      
      x += keyWidth + keySpacing
    }
  }
}
