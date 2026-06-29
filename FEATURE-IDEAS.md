# PartyHud 2026 — 功能點子探索 (Feature Ideas)

> 這是一份**腦力激盪 / backlog 文件**,不是已排程的開發計畫。
> 來源:2026-06-16 對其他 PartyHUD / 隊友狀態類 mod 的功能調查(研究 subagent + 人工綜合)。
> 目的:當未來想擴充 HUD 時的點子池;每項都附「價值 / 工時 / DST 限制 / 靈感來源 / 實作提示」,方便直接挑來做。

---

## 0. 怎麼讀這份文件

- **「價值」「工時」是粗估**(high / med / low),用來抓 value-for-effort,不是承諾。
- 每項標注了 **DST 技術限制**,因為很多「看似簡單」的點子卡在資料拿不到(見下方「共通技術前提」)。
- 標 ✅ 的是「已扣掉我們現有功能」後**真正算新的**;與既有重複的不列。

### ⚠️ 研究限制(誠實註記)
做這份調查時,對外網路受限(Steam Workshop 頁面為 JS-heavy,WebFetch 抓不全)。因此**部分對比 mod 的功能描述是從 GitHub 原始碼 + 既有知識重建的,不是逐一驗證過的 live Workshop 頁面**。把本文件當「點子清單」看即可,真要做某項前,建議再去該 mod 的 Workshop / repo 確認它實際怎麼做。

### 目標 mod 的結論
使用者點名的 **Workshop `1233501056`「PartyHUD - Forked」就是 brianchenito 的 GitHub fork —— 也就是 PartyHud 2026 的直系祖先**。它有的(HP、max-penalty 弧、rate arrow、名字、死亡狀態、layout/position)我們**全都有了**,所以新點子全來自其他對比 mod。

---

## 1. 目前已有的功能基線(v2026.10 — SHIPPED 2026-06-18)

判斷「新不新」的對照基準 —— 以下**已經有了,不要重複列**:

- 每位隊友一個圓形 badge:名字 + 目前 HP(絕對數值)
- HP **max-penalty 弧**(無盡模式復活降上限,黑色 topper 從上往下蓋)
- **飢餓 / 理智**子環(絕對數值,hover 顯示數字)
- **著火 / 過熱 / 失溫**顏色脈動(橘 / 紅 / 青)+ HP 下降箭頭
- **理智速率箭頭**(上升/下降,含睡覺特例)
- 版面:**水平列** / **垂直自動換欄**(依螢幕高度、視窗縮放重排、避開地圖按鈕)
- 每位玩家可自訂選項:顯示自己的 badge / 子環開關 / HP 數字(always vs hover)
- **(v2026.8)跨 shard + 同-shard-遠距隊友**:看得到對面 shard(洞穴↔地面)與本 shard 超出網路視距的隊友;遠方隊友**變暗 + 標籤**(跨 shard =「Caves」/「Surface」、同 shard 遠 =「far」),視野內 local 永遠優先(不重複)。靠 shard mod RPC + `TheWorld.net` carrier `net_string` + 版本化 codec(`partyhud_statuscodec` / `partyhud_crossshard`)。選項 **Show Cross-Shard Teammates**。
- **(v2026.8)版面強化**:proportional-scale 換欄數穩定(縮放/小視窗不再塌成一欄)、per-column 高度(只有最右欄留地圖鍵空間)、閃避雨量計與角色第二排徽章(Abigail / 靈感)、**背包感知**(側背包左移 / 整合式背包底部預留,開關/裝卸/換背包即時反應)、死亡骷髏置中。
- **(v2026.9)crash 修正**:修掉 v2026.8 潛伏的伺服器 crash(裸 `tonumber` 不在 modmain 沙箱環境 → 玩家加入洞穴叢集時 master shard 爆)。教訓寫進 `dst-mod-crash-audit` skill(沙箱 global 白名單 + pause_when_empty 遮蔽 sim-tick task 的 load-smoke 盲點)。
- **(v2026.10)低 HP 警示**:隊友 HP 低於門檻時徽章邊框**平滑紅色呼吸**(circleframe 通道,與火焰脈動共存;遠距/跨-shard 也脈動)。每人選項 **Low-HP Alert: Off / 40% / 25%(預設) / 15%**(占 max HP)。無音效(刻意)。
- **(v2026.12)隊友頭像 + 名字配色**:每個 badge 可顯示隊友的角色頭像 —— 角落小頭像(Corner)或在 HP 環中央的動畫角色臉(Centred);頭像反映玩家的角色 skin,遠距/跨-shard 隊友也顯示。置中樣式下著火/過熱/失溫/HP 速率箭頭出現時自動翻成角落(讓箭頭不被臉擋)。名字配色(Colour Teammate Names):每人名字染成其玩家顏色。
- **(v2026.13)Skip-self 跨 shard 修正**:「顯示自己的 badge: Skip」在開啟跨 shard 時不再重新出現為變暗的「far」badge。
- **(v2026.14)Combined Status 相容 + hover 優化**:
  - 同時安裝 **Combined Status**(Workshop 376333686)時 badge 正確對齊 HP 環位置;CS 加的數字背景方框、badge 縮小、強制顯示數字等 side-effect 全部消除,hover-only 行為保留。
  - 變暗(遠距/Caves/Surface)badge 的 hover 數字不再在 ~0.5s 後閃回變暗 —— 整個 hover 期間維持完全可見。
  - 排版補償現通用於任何縮放 HUD anchor 的 mod。

---

## 2. 共通技術前提(reusable,決定每個點子的工時)

這些是 DST 架構限制,反覆出現在下面的「限制」欄,先集中講:

1. **owner-only classified 資料**:溫度、濕度、精確 buff 狀態等都掛在每位玩家的 `player_classified`,**只對該玩家自己的 client 廣播**。要顯示隊友的這些值,得像我們現在對 HP/hunger/sanity 一樣**在 server hook 廣播自訂 netvar**(不能在 client 直接讀隊友的)。延伸現有 pattern 即可,但每多一個值就多一組 netvar + hook。
2. **跨 shard(洞穴↔地面)**:`AllPlayers` 是 shard-local + 限網路視距。要顯示對面 shard 的隊友,**唯一可行傳輸是 shard mod RPC**(`SendModRPCToShard`,server↔server,payload 要序列化成 string)。**✅ 這套基礎建設在 v2026.8 已經蓋好且可擴充** —— shard RPC + `TheWorld.net` carrier `net_string` + **帶 protocol version byte 的 codec**(`partyhud_statuscodec`,v1→v2 已示範加 `origin` 欄位)。所以「某個新數值也要跨 shard 看到」現在只是 **bump codec 版本 + 加一個欄位 + 既有 server hook 廣播**,不再是從零搭傳輸。新 codec 欄位記得保持 backward-tolerant decode(舊 peer 解不到新欄位 → nil,優雅降級)。見 memory `partyhud-v2026-8-crossshard-research`。
3. **server hook 才拿得到的資料**:背包 / 裝備 / 手持物等不在 classified,要額外 server-side 廣播 —— 工時高、CP 值通常低。
4. **視覺對齊**:任何新 widget 都該跑 `dst-badge-visual-audit` skill(build 名 / tint / scale / z-order / 填充方向),避免重蹈 penalty 弧反向那種雷。

---

## 3. 🏆 Top 5(value-for-effort 排序)

### 1. 數值文字 + hover 詳情面板  ✅
- **是什麼**:在環上/下顯示 `112/150` 這類絕對數值;hover badge 時跳出完整 stat 面板(HP/飢餓/理智/溫度/濕度…一次看)。
- **為什麼**:資訊密度大增但不雜亂(平時看環、要細節才 hover)。
- **靈感**:Combined Status(`Show Max Text`、數值顯示)、Full Stats Party HUD。
- **價值 高 / 工時 低**。資料我們已經在讀(classified netvar),純 client。
- **實作提示**:加一個「顯示數字 / 只顯示環」設定;hover 面板用標準 widget focus handler。跟下面第 4 項「精簡/詳細切換」天生一對。

### 2. 可設定的低 HP 閃爍警示  — ✅ 已出貨 (v2026.10)
- **是什麼**:隊友 HP 低於門檻時 badge 警示。
- **狀態**:**v2026.10 已實現** —— 徽章邊框(circleframe)**平滑紅色呼吸**(1.2s sine breathe,用現成 `Lerp`),每人選項 `Low-HP Alert: Off/40/25/15`(占 max HP)。與火焰/過熱/失溫脈動**共存**(不同元件 = warning pulse vs circleframe),遠距/跨-shard 徽章也脈動。**無音效**(co-op 易刷,刻意不做)。實作上沒沿用 thermal 的 `StartWarning`(那是單一連續脈動通道),而是另起 circleframe + `StartUpdating/OnUpdate` 逐幀 lerp,經單一寫入者 `_apply_frame_colour` 與 foreign-dim 協調。保留此條僅作紀錄;不再是 backlog 項目。

### 3. 角色頭像 + 名字配色  — ✅ 已出貨 (v2026.12)
- **是什麼**:環中心放該角色的 avatar 圖(取代通用環),名字用玩家自己的顏色。
- **狀態**:**v2026.12 已實現** —— Centred head(環中央動畫臉)/ Corner(角落小頭像)/ Off 三段選項;反映 skin;遠距/跨-shard 也顯示;置中樣式下熱效果箭頭出現時自動翻角落。名字配色選項 Colour Teammate Names。保留此條僅作紀錄;不再是 backlog 項目。

### 4. 精簡/詳細模式切換 + 隱藏 HUD 熱鍵  ✅
- **是什麼**:一鍵在「只有環的迷你 badge」與「完整 stat badge」之間切換;另一鍵整個收起 party HUD。
- **為什麼**:便宜的 QoL,跟我們現有的 layout 系統互補(layout 管排列,這個管密度)。
- **靈感**:Full Stats Party HUD 的 `\` 切換鍵。
- **價值 中高 / 工時 低**。純 client keybind。
- **實作提示**:用 mod 的 key-bind 設定;切換時改 badge 的子元件顯示 + 重排。

### 5. 洞穴/地面(shard)所在指示  — ✅ 已出貨 (v2026.8)
- **是什麼**:badge 標出隊友目前在哪個 shard(地面 / 洞穴)。
- **狀態**:**v2026.8 已實現** —— 跨 shard 隊友標「Caves」/「Surface」,同-shard-遠標「far」,皆變暗。原本「工時 高 — 卡跨 shard plumbing」已不成立(plumbing 蓋好了)。保留此條僅作紀錄;不再是 backlog 項目。

**榮譽提名**:**點 badge → 地圖 ping / 聊天宣告**(Global Positions 的 alt+click ping + Status Announcements)。價值高;最便宜的純 client 版本是「在聊天宣告該玩家狀態/位置」,真正的地圖 ping 需要更多 plumbing。

---

## 4. 完整分類清單(備查)

### 額外狀態
| 點子 | 是什麼 | 靈感來源 | 價值/工時/限制 |
|---|---|---|---|
| 數值文字 | 環上顯示 `112/150` 而非只有弧 | Combined Status、Full Stats | 高 / 低。資料已在手(見 Top 5 #1) |
| 溫度數值 | 每位隊友的實際溫度數字 + 過熱/失溫圖示 | Combined Status(°C/°F 切換) | 中 / 低–中。我們已脈動提示冷熱,加數值是增量;溫度是 owner-only → 需 server 廣播 |
| 濕度 / wetness | 隊友的濕度(下雨/碰水)。原版有 **on-demand 的 `moisturemeter`**(`widgets/moisturemeter.lua`:moisture>0 才彈出、=0 收起,WX-78 有變體)可參考視覺 + 速率箭頭 | (空白,沒 party mod 做) | 中 / 中。**濕度在 player_classified = owner-only,隊友讀不到**(`player_common.lua:238` 走 classified、`:1016` SetClassifiedTarget;subagent 一度誤稱可直讀,已更正)→ 要跟 HP/理智一樣 **server-hook 廣播自訂 netvar**(+ 跨 shard relay),不是免費的。價值:雨衣/傘/牛帽讓累積速率差很多 → 看誰快濕透該換裝,速率箭頭尤其有用 |
| 船體血量 / boat | 隊友所在船的船體 HP。原版 **on-demand 的 `boatmeter`**(`widgets/boatmeter.lua`:踏上有 `healthsyncer` 的平台才顯示、下船消失) | (空白) | 低 / 中。船是**共享世界狀態**(同船者本來就各自看得到),只有多船 session 對「別船隊友」才有意義 → 實用優先度低 |
| 死亡 vs 幽靈區分 | 屍體待救 vs 遊蕩幽靈用不同圖示 | Full Stats(骷髏)、Forked(arcane) | 中 / 低。我們已有死亡;拆「待救/幽靈」增加救援急迫性。需 ghost 事件(我們已處理) |
| buff/debuff 列 | 海狸/變身/吃飽/睡覺等小圖示 | (空白) | 中 / 高。狀態太多、classified 暴露程度不一 → defer |
| 裝備窺視 | 顯示隊友的武器/光源/護甲 | (空白) | 低–中 / 高。背包不在 classified → 需 server hook;**CP 值低,先跳過** |

### 互動
| 點子 | 是什麼 | 靈感來源 | 價值/工時/限制 |
|---|---|---|---|
| 點擊 → ping/宣告 | 點 badge 在地圖 ping 或聊天宣告該隊友 | Global Positions(alt+click ping)、Status Announcements | 高 / 中。badge 已是可點 widget;chat 宣告版純 client 最便宜,地圖 ping 需 plumbing |
| hover → 詳情 tooltip | hover 顯示完整 stat 區塊 | Combined Status | 高 / 低–中(見 Top 5 #1) |
| 點擊 → 方向指示 | 點擊高亮指向該玩家的螢幕外箭頭 | Global Positions、Extended Indicators、Compass | 中 / 中–高。indicator 是獨立子系統,整合非平凡,但導航性強 |

### 視覺
| 點子 | 是什麼 | 靈感來源 | 價值/工時/限制 |
|---|---|---|---|
| 角色頭像 | 環中心放 avatar | (隊友 mod 空白) | ✅ **已出貨 v2026.12**(Corner / Centred head / Off;含 skin;跨 shard 也顯示) |
| 名字配色 | 每人名字用其顏色 | Global Positions | ✅ **已出貨 v2026.12**(Colour Teammate Names 選項) |
| **名字字體大小選項** | 用設定切換名字字型大小:小 / 中 / 大 | (使用者需求) | 中 / **低**。純 client 視覺選項(`client = true` config,`GetModConfigData("name", true)` 取本地值);名字 Text widget 已存在,只需把寫死的 `SetSize(...)` 改成讀設定值的對應字級。注意:字變大時要連動 badge 的縱向預留/排版(`compute_percol`/`layout_badges`),否則大字會疊到下一列;跨 shard 的 "elsewhere" 名字標籤(`SetForeign` 的 soft-blue label)也應一併套用同一字級。屬「好做的小品質選項」。 |
| 精簡/詳細切換 | 一鍵切密度 | Full Stats(`\`) | 高 / 低(見 Top 5 #4) |
| 隱藏 HUD 熱鍵 | 綁鍵收起整個 party HUD | Full Stats | 中 / 低。純 client keybind |
| 更多錨點預設 | 右上角等更多位置 | Better PartyHUD(右上) | 低–中 / 低。已有 layout,加預設即可 |

### 警示
| 點子 | 是什麼 | 靈感來源 | 價值/工時/限制 |
|---|---|---|---|
| ~~低 HP 閃爍/音效~~ | 隊友低於門檻時閃 | (DST 隊友 mod 空白) | ✅ **已出貨 v2026.10**(平滑紅色呼吸邊框;無音效) |
| 死亡/復活 toast | 「X 死了 / 復活了」短暫提示 | Status Announcements(手動);自動化是空白 | 中高 / 中。我們已有 presence/ghost 事件;注意大伺服器刷屏 |
| 著火/結凍 toast | 隊友著火時彈提示 | (空白;我們已脈動) | 低 / 低。已脈動,toast 是小增量 |

### 存在 / 位置
| 點子 | 是什麼 | 靈感來源 | 價值/工時/限制 |
|---|---|---|---|
| ~~洞穴/地面指示~~ | badge 標所在 shard | (沒人乾淨做) | ✅ **已出貨 v2026.8**(Caves/Surface/far 標籤) |
| AFK/閒置指示 | 玩家沒動就變暗/顯示 Z | (空白) | 低–中 / 中。需 client 端追蹤移動,距離/跨 shard 下不可靠 |
| 距離/方向 | 顯示與隊友的距離 + 箭頭 | Global Positions、Extended Indicators、Compass | 中 / 中。同 shard 方向簡單,距離數字是不錯的疊加 |
| 狀態分享 opt-out | 讓玩家隱藏自己的詳細狀態 | Global Positions(scoreboard opt-out) | 低 / 中。禮貌性功能,需共享 netvar flag,對狀態 HUD 大概過度設計 |

---

## 5. 角色專屬狀態(進階,Tier 4)

DST 每個角色除了血/餓/智三圍,還各有一條**獨門機制條**。這層是「要不要在隊友 badge 上多顯示該角色的專屬狀態」。價值高(資訊量大)但屬進階,且**每個角色都要個別處理**,工時隨支援的角色數線性增加 → 整層歸 Tier 4(緩議)。

**共通限制(重要)**:這些值多半在 `player_classified`,而 classified 是 **owner-only**(只對玩家自己廣播)→ 顯示隊友的仍需 **server hook 廣播自訂 netvar**,跟我們現在 HP 的做法一樣。「2016 後新角色已同步」指的是 Klei 官方把值放進了 classified(資料源存在、好取),**不代表 client 能直接讀隊友的**。

### 5a. 官方已在 classified 同步(資料源現成,相對好做)
| 角色 / 機制 | 是什麼(給新手) | 價值/工時/限制 |
|---|---|---|
| **理智模式(瘋狂 vs 啟蒙/月之瘋癲)** | 全遊戲機制,非角色專屬:低理智會進「瘋狂 Insanity」(黑影怪)或月島區的「啟蒙/Lunacy」(月之系敵人)。影響理智環該用哪種顏色/行為 | 中 / 低–中。我們理智環目前固定橘(一般模式);加模式判斷可正確切色。曾踩誤用月之藍的雷 |
| **Woodie 變身形態** | 被詛咒的伐木工,砍太多樹/滿月會變身成 Werebeaver(海狸)/Weremoose(駝鹿)/Weregoose(鵝),變身時三圍規則全換,另有詛咒/木頭計量 | 中 / 中。顯示「目前是否獸形 + 哪種」對隊友有用;變身狀態可能要 tag + netvar |
| **Wigfrid 靈感 Inspiration** | 女武神,戰鬥累積「靈感」用來唱戰歌給隊友 buff | 低–中 / 中。第四條資源,小眾 |
| **Wolfgang 力量 Mightiness** | 大力士,舉啞鈴+吃飽在 強壯/普通/虛弱 間變動,越強傷害/移速越高 | 中 / 中。看隊友是不是虛弱(脆)有戰術價值 |
| **Wanda 年齡 Age** | 時間旅人,**沒有傳統血量邏輯**:用「年齡」代替(老=上限高但脆,年輕=耐打但上限低)。她的「血條」其實是年齡 | 中 / 中–高。我們的 HP 環對 Wanda 語意不同,要特判才不會誤導 |

**實作備註 —— 理智模式偵測 → 子環切色/圖示(對照 `widgets/sanitybadge.lua`):**
- **資料源**:`sanity:GetSanityMode()` → `SANITY_MODE_INSANITY`(瘋狂)或 `SANITY_MODE_LUNACY`(月之/啟蒙)。owner-only,跟其他 status 一樣要在 **server hook 廣播自訂 netvar**(一個 `net_bool`/`net_tinybyte` 即可,搭現有 `customhpbadgedirty`)。可在 `onsanitydelta` 順手帶(mode 變動也會觸發 sanitydelta-ish 更新;保險可額外監聽模式切換)。
- **客端切換**(原版 `SanityBadge:DoTransition`):
  - 瘋狂 → 環色 `SANITY_TINT = {232,123,15}/255`(橘)、一般 brain 圖示(symbol `icon`)。
  - 月之 → 環色 `LUNACY_TINT = {191,232,240}/255`(淡藍)、背景 override `bg`→`lunacy_bg`、圖示 override `icon`→`lunacy_icon`(都在 build `status_sanity`)。
  - 原版有轉場動畫 `transition_sanity`/`transition_lunacy` + FX;我們的小子環**可省略轉場**,直接 set tint/symbol 即可(子環很小,轉場看不太出來)。
- **顏色語意翻轉雷**:原版 `PulseGreen` 在月之模式下會改閃紅(理智「上升」在月之模式概念上是反的)。若我們有理智上升的綠閃,記得同步翻轉,否則語意會錯。
- **工時/取捨**:tint + symbol override 本身低工時;主要成本是多一條 netvar + 處理子環在 `status_sanity` build 上做 symbol override(我們子環目前是 `Badge(nil,...,"status_sanity",...)`,已用該 build,可行)。屬「好做但小眾」,可跟其他 5a 項一起做或單獨做。

### 5b. 需自建 netvar(較麻煩,先緩)
| 角色 / 機制 | 是什麼(給新手) | 價值/工時/限制 |
|---|---|---|
| **Wortox 靈魂 Souls** | 小惡魔,殺生物掉「靈魂」,撿了可瞬移/吃靈魂回血 | 低–中 / 中–高。靈魂數要自建 netvar |
| **Wormwood 開花 Blooming** | 植物人,隨季節/施肥進入「開花」階段拿 buff,且**不能靠吃食物回血**(用施肥/治療) | 低–中 / 中–高。開花階段要自建 netvar |
| **Wendy / Abigail 羈絆** | Wendy 能召喚妹妹鬼魂 Abigail 助戰,Abigail 有自己的血量/階段 | 中 / 中–高。「召沒召出來」用 tag 很便宜;Abigail 血量/羈絆等級要另做 |

> 實作策略建議:若哪天要做,**先做「召喚物/變身存在與否」這種 tag 判斷便宜的**(Abigail 在不在、Woodie 是不是獸形),再視需求才碰需自建 netvar 的數值。整層可當「角色玩家多的伺服器」才值得的加值。

---

## 6. 對比 mod 來源清單

- **PartyHUD - Forked**(目標 1233501056,= 我們祖先):<https://steamcommunity.com/sharedfiles/filedetails/?id=1233501056> · GitHub <https://github.com/brianchenito/PartyHud>
- **PartyHUD - Team Health Display**(782961570,原始版,HP-only)
- **Full Stats Party HUD - Beta**(2507838386,HP+飢餓+理智、暱稱、骷髏、切換鍵)
- **Better PartyHUD [Server-Side]**(1744248564,移到右上角)
- **Combined Status**:<https://github.com/rezecib/Combined-Status>(數值/溫度/hover,**client-only,非跨 shard**)。**v2026.14 已全面相容** —— CS 的 `AddClassPostConstruct` side-effect(bg 方框、badge 縮小、num 外移、hover 強制顯示、HUD anchor rescale + sidepanel 位移)全部消除;詳見 `.claude/skills/dst-badge-visual-audit` item 11a。
- **Global Positions**:<https://github.com/rezecib/Global-Positions>(地圖位置、ping、顏色;carrier-entity 渲染模式參考)
- **Status Announcements**(343753877)
- Monster/Simple/Epic Healthbars(786566397 / 1608490902 / 1185229307,頭上血條點子)

---

*相關:跨 shard 的技術設計見 memory `partyhud-v2026-8-crossshard-research`;視覺實作前跑 `.claude/skills/dst-badge-visual-audit`。*
