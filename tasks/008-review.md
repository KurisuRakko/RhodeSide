# 008 反方审稿：桌宠页 / 选模型 / 设置页重写

审的是 2026-09-30 15:48 的文件（审稿期间 ModelPicker.tsx:125 补上了 `rs-picker` 类名，结论按补上之后的版本；之后到 15:52 再没有变动）。
只读：`tsc --noEmit -p tsconfig.json` 通过，`scripts/check-design.mjs` 通过。

## P1

### 1. 选模型页右栏：没有控件的行被压成 40px 宽的竖条（在线模型每次都会碰到）
- 位置：`web/src/settings/settings.css:260-262`（`.rs-picker__right .rs-line__text { flex: 0 0 40px; }`），出问题的行在 `web/src/settings/ModelPicker.tsx:208-218`
- 触发：在选模型页点任意一个**在线（没下载）模型**，或者焦点为空时（「在左边选一个模型」）。
- 原因：这条规则本来是给「时装 / 形态」两行用的（名字只有 2 个字）。但在线模型那一行 `Row label="还没下载"/"下载失败"`、hint 是「共 N 套时装，下载后可以选时装和形态 · x MB」或下载失败的错误原文，这一行**没有 children**，所以不会渲染 `.rs-line__control`。文字列的 flex-basis 被固定成 40px、`flex-grow: 0`，整句 hint 只能挤在 40px 宽里，每行大约 3 个汉字，折成十几行。右栏是 `flex-direction: column`，`.rl-preview` 用的是 `flex: 1` 加 `min-height: 0`，所以窗口矮的时候（最小 680×480）预览画布会被挤到几乎看不见。「在左边选一个模型」也会折成 3 行。
- 修法：把这条规则限定在带控件的行上，例如改成 `.rs-picker__right .rs-line:has(.rs-line__control) .rs-line__text`。或者给这两行单独加一个类（比如 `rs-line--narrow`），别把整个右栏的 `.rs-line__text` 都改掉。

### 2. 当前模型的时装列表载入失败时，直接点「使用」会清掉桌宠的时装、形态和循环动作
- 位置：`web/src/settings/ModelPicker.tsx:75`（失败时 `setSets([])`）、`:92`、`:95`、`:112-113`、`:228`
- 触发：给桌宠打开选模型页，焦点停在它**正在用的模型**上，而 `modelSets()` 失败了（骨骼或图集 fetch 404、scheme handler 偶发出错、collectSets 抛错），用户以为什么都没改，点了「使用」。
- 原因：`sets = []` 时 `outfits` 为空，`outfit` 解析为 `null`，`group` 也是 `null`。而 `nowOutfit = pet.outfit`（非空），所以 `changed = true`，发出 `updatePet {model, outfit: null, group: null, pose: null}`。Swift 端 `merged()`（`macos/Sources/Rhodeside/WebBridge.swift:78`）会把 NSNull 当成清空字段，于是配置里的时装、形态、战斗形态的循环动作都被抹掉，桌宠退回默认时装。按钮只在 `sets === null` 时禁用，`[]` 时是可以点的。
- 修法：`sets` 为空数组时禁用「使用」（或者显示「读不到这个模型的时装」）。至少在 `isCurrent && sets.length === 0` 时不要发 outfit/group/pose。更稳的做法是 patch 里只放真正改了的字段。

### 3. 预览区写着「点一下播攻击」，实际点了没反应（误导）
- 位置：`web/src/settings/ModelPicker.tsx:186`（`note='战斗形态不会走动，点一下播攻击'`），在 `web/src/library/Library.tsx:227-230` 显示成预览画布标题栏右边的小字
- 触发：在选模型页选中正面 / 背面形态。
- 原因：这句话说的是桌面上的桌宠，但它就显示在预览画布下面，用户自然会去点预览。预览用的 Stage 是 `setMode('view')`，而 `web/src/stage/engine.ts:414` 的 `onDown` 在 `mode !== 'roam'` 时直接 return，点了没有任何反应。
- 修法：文案改成「战斗形态在桌面上不会走动，点一下桌宠会播攻击」。或者干脆在预览里接上点击播攻击，让文案成真。

## 查过、没发现问题的点（供参考）
- **消息约定**：`updatePet {model, outfit, group, pose: null}` 和 `downloadModels {ids}` 的字段与 `bridge.ts` 的 Outgoing、`SettingsController.swift:171/232`、`PetManager.updatePet` 一致。`null` 由 `merged()` 转成 nil，语义是「用模型默认」，和旧版选模型时发的 `{model, outfit: null, group: null, pose: null}` 一样。「下载并使用」先发 download 再切模型，Swift 在模型不存在时会显示「还没下载」，下载完由 `modelFilesMaybeChanged` 重新载入，行为和旧版相同。
- **默认时装**：ModelPicker 和 PetEditor 在没指定时装时用 `outfits[0]`（按 localeCompare 排序），桌宠端 `pickSet` 用的是 `defaultskin/`。我对服务器上全部 137 个模型核对过，两者都指向同一套时装，所以不会出现界面显示和实际不一致。
- **重复载入 / 闪烁**：原生层每次推送的 state 都是新对象，但 `sets` 的 effect 按 `name + files` 做 key，`ModelPreview` 按 `JSON.stringify(source)` 做 key，推送本身不会触发重载。在线模型下载完变成本地模型时会从在线预览切到本地预览，这次重载是预期的。
- **竞态和纹理**：快速切换时，旧的载入被 `alive` 挡住，已经建好的纹理会被 dispose；在线预览的 listener 在 cleanup 里 off 掉，旧的 preview 回包不会覆盖新的预览。
- **Library.tsx 的 `localCache`**：key 是 `name + 完整文件列表`（路径里带模型文件夹名），不会把一个模型的数据给另一个名字；失败时只清掉仍是自己的那个条目，不会卡死。
- **删掉的功能**：旧包 `settings-DuZAuwHS.js` 发出的消息类型在新界面里都还在（addPet / removePet / summonPet / perform / playCombo / updateGlobal ×4 / setLoginItem / reveal ×3 / snapshot / reloadWeb / checkUpdates / auth* / import* / deleteModel / downloadModels）。旧版的「应用版本 → 远端版本」改成了一句 updateSummary，信息少了一点，但不算丢功能。
- **CSS**：旧 settings.css 里删掉的类（rs-card* / rs-section* / rs-field / rs-grid / rs-label* / rs-switch / rs-toggle* / rs-more / rs-sub / rs-head / rs-app）在 `web/src` 和 `web/*.html` 里都已经没有引用；现在用到的类也都有定义。

## 低优先级（不算 P1，顺手记一下）
- `tasks/003-smoke.py` 还在用 `.rs-card` / `.rs-section__title` / `aria-label='模型'` 这些选择器，已经跑不通了。如果以后还要拿它当回归测试，需要重写。
- `localCache` 和 `validate.ts` 的 `modelSets` 缓存都只按文件路径做 key。模型原地更新（outdated 重新下载、路径不变）后，窗口不重开的话，会拿旧的骨骼 / 图集去配新的贴图。概率很低。
- 选模型页第一次打开时，`sets === null` 那一帧 `Pick` 会显示「char_xxx（不可用）」。
- 在线模型在页面开着的时候下载完成：焦点会切到本地模型，但左侧列表里没有任何一行是高亮的（`focus` 还是 `{kind: 'online'}`）。
