import Foundation

/// 语音后处理流水线
/// L2: PolishClient 语义润色（可关闭）
/// 注入 → 历史落盘
@MainActor
final class VoicePipeline {
    private let history = VoiceHistory()

    func process(
        transcription: TranscriptionResult,
        targetApp: AppIdentity?
    ) async {
        let tStart = CFAbsoluteTimeGetCurrent()
        let rawText = transcription.fullText
        Logger.log("Pipeline", "Raw: \(rawText)")

        // L1: normalize punctuation when English is detected (Chinese recognizer always outputs
        // Chinese punctuation regardless of spoken language)
        let l1Text = normalizePunctuation(rawText)
        if l1Text != rawText {
            Logger.log("Pipeline", "L1: punctuation normalized (English detected)")
        }

        // L2: 模型润色（polish.enabled = false 时跳过）
        let finalText: String
        let polished: String?
        var l2ElapsedMs = 0
        if RuntimeConfig.shared.polishConfig["enabled"] as? Bool == true {
            let tL2 = CFAbsoluteTimeGetCurrent()
            polished = await PolishClient.shared.polish(
                text: l1Text,
                words: transcription.words,
                app: targetApp
            )
            l2ElapsedMs = Int((CFAbsoluteTimeGetCurrent() - tL2) * 1000)

            // 无条件记录 L2 真实行为：nil / identity / 真改
            let kind: String
            if polished == nil { kind = "nil" }
            else if polished == l1Text { kind = "identity" }
            else { kind = "changed" }
            Logger.log("Pipeline", "L2: elapsedMs=\(l2ElapsedMs) kind=\(kind) output=\(polished ?? "<nil>")")

            finalText = polished ?? l1Text
        } else {
            polished = nil
            finalText = l1Text
            Logger.log("Pipeline", "L2: skipped (polish.enabled=false)")
        }

        // 注入到焦点应用
        let tInject = CFAbsoluteTimeGetCurrent()
        TextInjector.inject(text: finalText, to: targetApp)
        let injectMs = Int((CFAbsoluteTimeGetCurrent() - tInject) * 1000)

        // 历史落盘（始终写入，蒸馏需要）
        history.save(
            transcription: transcription,
            l1Text: l1Text,
            polishedText: polished,
            finalText: finalText,
            app: targetApp
        )

        let totalMs = Int((CFAbsoluteTimeGetCurrent() - tStart) * 1000)
        Logger.log("Pipeline", "Timing: l2=\(l2ElapsedMs)ms inject=\(injectMs)ms pipeline_total=\(totalMs)ms")
    }

    // Detects if text is predominantly Latin-script and converts Chinese punctuation to
    // English equivalents. Chinese text is returned unchanged.
    private func normalizePunctuation(_ text: String) -> String {
        var latinCount = 0
        var cjkCount = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (v >= 0x0041 && v <= 0x005A) || (v >= 0x0061 && v <= 0x007A) {
                latinCount += 1
            } else if (v >= 0x4E00 && v <= 0x9FFF) || (v >= 0x3400 && v <= 0x4DBF) {
                cjkCount += 1
            }
        }
        guard latinCount > cjkCount else { return text }

        return text
            .replacingOccurrences(of: "。", with: ".")
            .replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "！", with: "!")
            .replacingOccurrences(of: "？", with: "?")
            .replacingOccurrences(of: "；", with: ";")
            .replacingOccurrences(of: "：", with: ":")
            .replacingOccurrences(of: "、", with: ",")
            .replacingOccurrences(of: "「", with: "\"")
            .replacingOccurrences(of: "」", with: "\"")
            .replacingOccurrences(of: "（", with: "(")
            .replacingOccurrences(of: "）", with: ")")
            .replacingOccurrences(of: "【", with: "[")
            .replacingOccurrences(of: "】", with: "]")
            .replacingOccurrences(of: "…", with: "...")
    }
}
