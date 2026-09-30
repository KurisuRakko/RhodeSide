import Foundation

/// 连招里的一步：播一次（loop = false，seconds = 动画时长，网页 animDone 没来时兜底）或循环 seconds 秒
public struct ComboStep: Equatable, Sendable {
    public var name: String
    public var loop: Bool
    public var seconds: Double

    public init(name: String, loop: Bool, seconds: Double) {
        self.name = name
        self.loop = loop
        self.seconds = seconds
    }
}

/// 控制面板里的一个按钮：一串按顺序播的动画。
/// 哪些动画算一套由网页认（`web/src/stage/combos.ts`，各平台共用），随 `loaded` 消息发过来；这里只管播
public struct Combo: Equatable, Sendable {
    public var id: String
    public var label: String
    public var steps: [ComboStep]

    public init(id: String, label: String, steps: [ComboStep]) {
        self.id = id
        self.label = label
        self.steps = steps
    }
}
