//
//  InputSource.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit

final class SquirrelInstaller {
  enum InputMode: String, CaseIterable {
    static let primary = Self.hans
    case hans = "im.rime.inputmethod.Squirrel.Hans"
    case hant = "im.rime.inputmethod.Squirrel.Hant"
  }
  private lazy var inputSources: [String: TISInputSource] = {
    var inputSources = [String: TISInputSource]()
    var matchingSources = [InputMode: TISInputSource]()
    let sourceList = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
    for inputSource in sourceList {
      let sourceIDRef = TISGetInputSourceProperty(inputSource, kTISPropertyInputSourceID)
      guard let sourceID = unsafeBitCast(sourceIDRef, to: CFString?.self) as String? else { continue }
      // print("[DEBUG] Examining input source: \(sourceID)")
      inputSources[sourceID] = inputSource
    }
    return inputSources
  }()

  func enabledModes() -> [InputMode] {
    var enabledModes = Set<InputMode>()
    for (mode, inputSource) in getInputSource(modes: InputMode.allCases) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        enabledModes.insert(mode)
      }
      if enabledModes.count == InputMode.allCases.count {
        break
      }
    }
    return Array(enabledModes)
  }

  func register() {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty {
      print("User already registered Squirrel method(s): \(enabledInputModes.map { $0.rawValue })")
      // Already registered.
      return
    }
    TISRegisterInputSource(SquirrelApp.appDir as CFURL)
    print("Registered input source from \(SquirrelApp.appDir)")
  }

  func enable(modes: [InputMode] = []) {
    let enabledInputModes = enabledModes()
    if !enabledInputModes.isEmpty && modes.isEmpty {
      print("User already enabled Squirrel method(s): \(enabledInputModes.map { $0.rawValue })")
      // keep user's manually enabled input modes.
      return
    }
    let modesToEnable = modes.isEmpty ? [.primary] : modes
    for (mode, inputSource) in getInputSource(modes: modesToEnable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), !enabled {
        let error = TISEnableInputSource(inputSource)
        print("Enable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      }
    }
  }

  func select(mode: InputMode? = nil) {
    let enabledInputModes = enabledModes()
    let modeToSelect = mode ?? .primary
    if !enabledInputModes.contains(modeToSelect) {
      if mode != nil {
        enable(modes: [modeToSelect])
      } else {
        print("Default method not enabled yet: \(modeToSelect.rawValue)")
        return
      }
    }
    for (mode, inputSource) in getInputSource(modes: [modeToSelect]) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled),
         let selectable = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelectCapable),
         let selected = getBool(for: inputSource, key: kTISPropertyInputSourceIsSelected),
         enabled && selectable && !selected {
        let error = TISSelectInputSource(inputSource)
        print("Selection \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      } else {
        print("Failed to select \(mode.rawValue)")
      }
    }
  }

  func disable(modes: [InputMode] = []) {
    let modesToDisable = modes.isEmpty ? InputMode.allCases : modes
    for (mode, inputSource) in getInputSource(modes: modesToDisable) {
      if let enabled = getBool(for: inputSource, key: kTISPropertyInputSourceIsEnabled), enabled {
        let error = TISDisableInputSource(inputSource)
        print("Disable \(error == noErr ? "succeeds" : "fails") for input source: \(mode.rawValue)")
      }
    }
  }

  private func getInputSource(modes: [InputMode]) -> [InputMode: TISInputSource] {
    var matchingSources = [InputMode: TISInputSource]()
    for mode in modes {
      if let inputSource = inputSources[mode.rawValue] {
        matchingSources[mode] = inputSource
      }
    }
    return matchingSources
  }

  private func getBool(for inputSource: TISInputSource, key: CFString!) -> Bool? {
    let enabledRef = TISGetInputSourceProperty(inputSource, key)
    guard let enabled = unsafeBitCast(enabledRef, to: CFBoolean?.self) else { return nil }
    return CFBooleanGetValue(enabled)
  }
}

// MARK: - 为了双拼下的五笔反查尔增加

final class WubiCodeManager {
    static let shared = WubiCodeManager()
    
    private var codeMap: [String: String] = [:]
    private var isLoaded = false
    
    // 异步加载或者是首次访问加载
    func loadIfNeeded() {
        guard !isLoaded else { return }
        
        // 获取用户目录 ~/Library/Rime/wubi06_word_code.txt
        let fileURL = SquirrelApp.userDir.appendingPathComponent("wubi06_word_code.txt")
        
        do {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            
            for line in lines {
                // 跳过注释或空行
                if line.isEmpty || line.hasPrefix("#") { continue }
                
                // 假设格式为：字/词[tab/空格]编码
                // 例如: 蔑   ald
                let parts = line.split(whereSeparator: \.isWhitespace)
                if parts.count >= 2 {
                    let word = String(parts[0])
                    let code = String(parts[1])
                    
                    // 仅加载单字和二字词（根据你的需求优化内存）
                    if word.count <= 2 {
                        codeMap[word] = code
                    }
                }
            }
            isLoaded = true
            print("✅ [Squirrel] Wubi codes loaded: \(codeMap.count) entries")
        } catch {
            print("⚠️ [Squirrel] Failed to load wubi codes: \(error)")
        }
    }
    
    func getCode(for text: String) -> String? {
        if !isLoaded { loadIfNeeded() }
        return codeMap[text]
    }
}
