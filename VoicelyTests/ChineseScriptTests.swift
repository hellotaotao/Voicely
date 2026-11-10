import Foundation
import Testing
@testable import Voicely

/// Expected values come from the reference OpenCC library (Python opencc
/// 1.4.2, configs s2tw, s2hk and t2s).
struct ChineseScriptTests {
    static let toTraditional: [(input: String, taiwan: String, hongKong: String)] = [
        ("头发很长，发展很快。", "頭髮很長，發展很快。", "頭髮很長，發展很快。"),
        ("干部在干活，饼干很干。", "幹部在幹活，餅乾很乾。", "幹部在幹活，餅乾很乾。"),
        ("我们下周复习一下，然后回复邮件。", "我們下週複習一下，然後回覆郵件。", "我們下週複習一下，然後回覆郵件。"),
        ("这个软件的内存不够，视频卡住了。", "這個軟件的內存不夠，視頻卡住了。", "這個軟件的內存不夠，視頻卡住了。"),
        ("一只猫在里面，皇后来了。", "一隻貓在裡面，皇后來了。", "一隻貓在裏面，皇后來了。"),
        ("老板说下个季度的预算要重复确认。", "老闆說下個季度的預算要重複確認。", "老闆説下個季度的預算要重複確認。"),
        ("我哋今日开会，但系成本都涨咗唔少。", "我哋今日開會，但系成本都漲咗唔少。", "我哋今日開會，但系成本都漲咗唔少。"),
        ("OK 没问题, let's 重复一下。", "OK 沒問題, let's 重複一下。", "OK 沒問題, let's 重複一下。"),
        ("Meeting notes: 进度 on track.", "Meeting notes: 進度 on track.", "Meeting notes: 進度 on track."),
    ]

    static let toSimplified: [(input: String, simplified: String)] = [
        ("頭髮很長，發展很快。", "头发很长，发展很快。"),
        ("我們下週複習一下，然後回覆郵件。", "我们下周复习一下，然后回复邮件。"),
        ("這個軟體的記憶體不夠。", "这个软体的记忆体不够。"),
    ]

    @Test func matchesOpenCCForTaiwanAndHongKong() {
        for item in Self.toTraditional {
            #expect(ChineseScriptConverter.taiwan.convert(item.input) == item.taiwan)
            #expect(ChineseScriptConverter.hongKong.convert(item.input) == item.hongKong)
        }
    }

    @Test func matchesOpenCCForSimplified() {
        for item in Self.toSimplified {
            #expect(ChineseScriptConverter.simplified.convert(item.input) == item.simplified)
        }
    }

    @Test func changesCharactersButNeverWords() {
        // s2twp would write 軟體 and 記憶體; Voicely keeps what was said.
        #expect(ChineseScriptConverter.taiwan.convert("软件 内存 视频") == "軟件 內存 視頻")
    }

    @Test func conversionKeepsEveryCharacterInPlace() {
        for item in Self.toTraditional {
            let converted = ChineseScriptConverter.taiwan.convertKeepingLength(item.input)
            #expect(converted.utf16.count == item.input.utf16.count)
        }
    }

    @Test func sentenceThatWouldChangeLengthStaysAsWritten() {
        // 二𫫇英 becomes 二噁英: the rare character takes two UTF-16 units, its
        // replacement one. That sentence stays; the next one still converts.
        let text = "二𫫇英。头发"
        #expect(ChineseScriptConverter.taiwan.convert(text) != text)
        let kept = ChineseScriptConverter.taiwan.convertKeepingLength(text)
        #expect(kept == "二𫫇英。頭髮")
    }

    @Test func textWithoutChineseIsReturnedUntouched() {
        let text = "Quarterly planning, part 2."
        #expect(ChineseScriptConverter.taiwan.convertKeepingLength(text) == text)
    }

    @Test(arguments: [
        (["zh-Hant-TW"], ChineseScript.traditionalTaiwan),
        (["zh-Hant-HK"], .traditionalHongKong),
        (["zh-HK"], .traditionalHongKong),
        (["zh-Hant-MO"], .traditionalHongKong),
        (["zh-TW"], .traditionalTaiwan),
        (["zh-Hans-CN"], .simplified),
        (["zh-Hans-SG"], .simplified),
        (["en-AU", "zh-Hant-TW"], .traditionalTaiwan),
        (["en-US", "ja-JP"], .simplified),
    ])
    func defaultFollowsTheFirstChineseSystemLanguage(languages: [String], expected: ChineseScript) {
        #expect(ChineseScript.systemDefault(preferredLanguages: languages) == expected)
    }

    @Test @MainActor func savedChoiceWinsOverTheSystemDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "ChineseScriptTests-\(UUID().uuidString)"))
        let setting = ChineseScriptSetting(defaults: defaults)
        setting.script = .traditionalHongKong
        #expect(ChineseScriptSetting(defaults: defaults).script == .traditionalHongKong)
        #expect(setting.display("里面的系统") == "裏面的系統")
        setting.script = .simplified
        #expect(setting.display("里面") == "里面")
    }

    @Test func searchMatchesEitherScript() {
        let shown = ChineseScriptConverter.taiwan.convertKeepingLength("我们下周复习一下头发的问题。")
        #expect(shown == "我們下週複習一下頭髮的問題。")
        // Typed in Simplified, found in the Traditional text as shown.
        #expect(NoteSearch.ranges(of: "复习", in: shown) == [NSRange(location: 4, length: 2)])
        // Typed in Traditional, found in Simplified text.
        #expect(NoteSearch.ranges(of: "頭髮", in: "我们下周复习一下头发的问题。") == [NSRange(location: 8, length: 2)])
        // A single character with several Traditional forms still matches.
        #expect(NoteSearch.ranges(of: "发", in: shown).count == 1)
        #expect(NoteSearch.contains("Weekly sync", "sync"))
    }
}
