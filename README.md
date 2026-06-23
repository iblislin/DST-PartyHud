# PartyHud 2026

A modernized fork of [PartyHUD](https://github.com/brianchenito/PartyHud) by **brianchenito** — shows every teammate's status right on your HUD: health, hunger, sanity, on-fire and temperature, updated to work on current *Don't Starve Together*.

- **Source:** https://github.com/iblislin/DST-PartyHud
- **Steam Workshop:** https://steamcommunity.com/sharedfiles/filedetails/?id=3744675705

![PartyHud 2026 — vertical layout preview](preview.jpg)

## What's new in 2026
- Works on current DST (the original was last updated in 2016)
- Fixed a dedicated-server crash that triggered when a player disconnected, and the cave-entry / shard-migration crashes
- Fixed the invisible health badge (re-ported to the current `Badge` widget; build `health` → `status_health`)
- New **Vertical** layout, plus the classic **Horizontal** row
- Layout & position are now **per-player** settings (`client = true`)
- Minimap-friendly position presets; vertical anchor follows the position setting

### New in 2026.6 — richer status
- Each badge now shows a teammate's **hunger** and **sanity** as small sub-rings beneath the main **HP** ring
- All numbers are the **absolute in-game values** (e.g. `113`, not a 0–100 percent), matching the game's own meters; hover a sub-ring to read its number
- **On fire / overheating / freezing** show as a colour-coded warning pulse on the HP ring (orange / red / cyan)
- A **sanity rate arrow** mirrors the game's own gauge — rising/falling at three speeds
- Vertical layout **auto-wraps into columns** sized to your screen height, re-flows when you resize the window, and keeps clear of the map (M) button
- Two new per-player options: **Show Your Own Badge** and **Hunger/Sanity Sub-gauges** (hide them for a compact HP-only badge)

### New in 2026.7 — penalty & damage cues
- Max-HP and max-sanity **penalty** (from endless-mode resurrection) now shows as a darkened "lost max" arc on the ring, just like the game's own badges
- The HP ring shows a **down-arrow** when a teammate is losing health to fire / overheating / freezing, alongside the colour pulse
- The **sanity arrow now rises while a teammate is sleeping** (matching the game)
- More robust ghost / dead state and join / leave / cave-migration handling

### New in 2026.8 — cross-shard teammates + layout polish
- **See teammates on the other shard** (Caves ↔ Surface) and same-shard teammates who are out of network range — players who previously had no badge at all. Their status is relayed over an always-networked broadcast and refreshed ~2×/second.
- Far-away teammates render **dimmed** to signal the data is slightly delayed, labelled by where they are: **"Caves" / "Surface"** for a teammate on the other shard, **"far"** for one on your own shard but out of network range. A local (in-view) teammate always wins, so nobody is drawn twice mid-migration.
- **Fixed the column count on resized / small windows** — the vertical layout used to collapse every column to a single badge on a small window; it now accounts for the HUD's proportional scaling, so per-column count stays stable at any resolution.
- **Per-column heights**: only the rightmost column reserves space for the game's Map (M) button; the other columns extend nearly to the screen bottom.
- **Stays clear of the game's own UI**: the columns dodge the **rain (moisture) meter** and character status badges (**Wendy's Abigail**, **Wigfrid's inspiration**) when they appear below the status cluster — including the wider two-column case — and the dead-player **skull icon is now centred** on the badge.
- **Backpack-aware**: when a separate (non-integrated) backpack is open on the right, the whole HUD shifts left to clear it; with the **Integrated Backpack** option on, the columns reserve extra bottom space for the taller inventory bar. Reacts instantly as you open/close, equip/unequip, or **swap one open backpack for another**.
- New per-player options: **Show Cross-Shard Teammates** and a **[Test] Show mock badges** preview toggle. (Console helper `PartyHud_Layout()` switches Vertical/Horizontal live for debugging.)

### Fixed in 2026.9
- **Fixed a server crash** that hit a caves-enabled (two-shard) server when a player joined: a 2026.8 internal change called a function that isn't available in the mod's restricted environment, crashing the master shard once the cross-shard broadcast started. No gameplay/visual change — purely the crash fix. (If you ran 2026.8 on a caves cluster, update to 2026.9.)

### New in 2026.10 — low-HP alert
- A teammate's badge now **pulses a soft red ring border** when their HP drops below a threshold you choose, so "who's about to die" jumps out at a glance — the one cue no other DST teammate HUD has.
- New per-player option **Low-HP Alert: Off / 40% / 25% / 15%** (percent of their max HP; default 25%).
- The pulse **coexists with the fire/overheat/freeze warning** (different element, so a burning low-HP teammate shows both), and it works on **far / cross-shard** badges too — the teammate you can't see is exactly the one you most need flagged.

### New in 2026.12 — teammate avatars + name colours
- Each badge can now show the teammate's **character avatar**: a small head in the **Corner**, or the animated character **face centred** in the HP ring (the HP number becomes hover-only so the face is unobstructed). The avatar **reflects each player's chosen character skin**, and far / cross-shard teammates show theirs too.
- New per-player option **Teammate avatar: Off / Corner / Centred head** (default Centred head). In the centred style, a teammate's badge briefly **flips to the corner** while their fire / overheat / freeze / HP-rate arrow is active, so the arrow is never hidden behind the face.
- New per-player option **Colour Teammate Names** — tint each name in that player's own colour (default on).
- **Fixed:** a **far / cross-shard teammate's badge could vanish while they sat idle** (a data-staleness false positive); badges now stay put.

### Fixed in 2026.13
- **"Show Your Own Badge: Skip" now actually hides your badge.** With cross-shard teammates enabled (the default), your own badge used to reappear as a dimmed "far" badge even after you chose to skip it — your record arrives over the always-replicated cross-shard broadcast, and the skip only applied to the local pass. It's now suppressed on both. No change if you keep your own badge shown.

## Install (server mod)
Subscribe on the Workshop, **or** place this folder into your server's `mods/` as `partyhud` and enable it in each shard's `modoverrides.lua`:
```lua
["partyhud"] = { enabled = true }
```
Connecting players download it automatically. _(If you grab a GitHub source archive, rename the extracted folder to `partyhud`.)_

## Settings (each player chooses their own)
> These are **per-player client options**. To change them you must **subscribe to the mod on the Workshop** (or have it as a local client mod) so it appears in your **Mods → PartyHud 2026 → Configure** list. If you only auto-downloaded it by joining a server, you can still play and see the HUD, but with the **default** settings and no Configure entry — that's normal for a server mod's client options.

- **HUD Layout:** Horizontal / Vertical
- **HUD Position:** Minimap / Minimap XL / Standard
- **Show Your Own Badge:** Show / Skip (skip it — you already have your own status meters)
- **Hunger/Sanity Sub-gauges:** Show / Hide (hide for a compact HP-only badge)
- **Show Cross-Shard Teammates:** Show / Hide (teammates on the other shard or out of view range; on by default)
- **HP Number:** Always / On hover
- **Low-HP Alert:** Off / 40% / 25% / 15% (pulse a teammate's badge border red below this % of their max HP; default 25%)
- **Teammate avatar:** Off / Corner / Centred head (show each teammate's character on their badge; default Centred head)
- **Colour Teammate Names:** On / Off (tint each teammate's name in their own player colour; default on)
- **[Test] Show mock badges:** fills empty slots with fake teammates to preview the layout (only you see it; default off)

## Credits & License
Original PartyHUD by **brianchenito**, released into the public domain under [The Unlicense](LICENSE). Attribution is not required, but kept here with thanks for the original work.

---

## Steam Workshop description — English (copy-paste, Steam BBCode)

```
[b]PartyHud 2026[/b]

See your teammates' status right on your HUD — a badge for each player showing
their name, current HP, hunger and sanity, plus on-fire and temperature warnings,
so you always know who needs help.

A community update of the classic [b]PartyHUD[/b] by brianchenito, modernized
to work on current Don't Starve Together builds.

[b]What's new[/b]
[list]
[*] Works on current DST (the original was last updated in 2016)
[*] Fixed the dedicated-server disconnect crash and the cave-entry / shard crashes
[*] Fixed the health badge not showing (re-ported to the current badge UI)
[*] New [b]Vertical[/b] layout, plus the classic [b]Horizontal[/b] row
[*] Layout & position are now [b]per-player[/b] settings (Mods -> PartyHud 2026 -> Configure)
[*] Minimap-friendly position presets (Minimap / Minimap XL / Standard)
[/list]

[b]New in 2026.6 — richer status[/b]
[list]
[*] Hunger and sanity sub-rings beneath each HP ring; numbers are the real in-game
    values (hover a sub-ring to read it)
[*] On-fire / overheating / freezing shown as a colour-coded pulse on the HP ring
[*] A sanity rate arrow (rising/falling), mirroring the game's own gauge
[*] Vertical layout auto-wraps into columns to fit your screen and avoid the map button
[*] New options: Show Your Own Badge, and Hunger/Sanity Sub-gauges (hide for a compact badge)
[/list]

[b]New in 2026.7 — penalty & damage cues[/b]
[list]
[*] Max-HP / max-sanity penalty (from endless-mode resurrection) shown as a darkened "lost max"
    arc on the ring, like the game's own badges
[*] The HP ring shows a down-arrow when a teammate is losing HP to fire / overheating / freezing,
    alongside the colour pulse
[*] The sanity arrow now rises while a teammate is sleeping
[*] More robust ghost / dead state and join / leave / cave-migration handling
[/list]

[b]New in 2026.8 — cross-shard teammates + layout polish[/b]
[list]
[*] See teammates on the OTHER shard (Caves <-> Surface) and same-shard teammates out of network
    range — players who used to have no badge at all. Relayed over an always-networked broadcast,
    refreshed about twice a second
[*] Far-away teammates render dimmed and labelled: "Caves" / "Surface" for the other shard, "far"
    for your own shard out of range. A local (in-view) teammate always wins, so nobody is drawn twice
[*] Vertical layout column count is now stable on resized / small windows (accounts for HUD scaling)
[*] Columns reserve Map-button space only on the rightmost column; the rest extend toward the bottom
[*] Stays clear of the game's own UI — dodges the rain (moisture) meter and character status badges
    (Wendy's Abigail, Wigfrid's inspiration); the dead-player skull icon is now centred
[*] Backpack-aware: the HUD shifts left to clear an open side backpack, or reserves extra bottom space
    with the Integrated Backpack option; reacts instantly to open/close, equip/unequip, and pack swap
[/list]

[b]Fixed in 2026.9[/b]
[list]
[*] Fixed a server crash on caves-enabled (two-shard) servers that triggered when a player joined
    (a 2026.8 internal change used a function unavailable in the mod sandbox). No gameplay change;
    update to 2026.9 if you ran 2026.8 with caves.
[/list]

[b]New in 2026.10 — low-HP alert[/b]
[list]
[*] A teammate's badge pulses a soft red ring border when their HP drops below a threshold you pick,
    so "who's about to die" stands out at a glance
[*] New option Low-HP Alert: Off / 40% / 25% / 15% (percent of their max HP; default 25%)
[*] Coexists with the fire/overheat/freeze warning (different element) and works on far / cross-shard
    badges too
[/list]

[b]New in 2026.12 — teammate avatars + name colours[/b]
[list]
[*] Each badge can show the teammate's character avatar: a small head in the Corner, or the animated
    character face Centred in the HP ring (the HP number becomes hover-only). The avatar reflects each
    player's chosen character skin, and far / cross-shard teammates show theirs too
[*] New option Teammate avatar: Off / Corner / Centred head (default Centred head). In the centred style
    the badge briefly flips to the corner while a fire / overheat / freeze / HP-rate arrow is active, so
    the arrow is not hidden behind the face
[*] New option Colour Teammate Names — tint each name in that player's own colour (default on)
[*] Fixed: a far / cross-shard teammate's badge could vanish while they sat idle (a data-staleness false
    positive); badges now stay put
[/list]

[b]Fixed in 2026.13[/b]
[list]
[*] "Show Your Own Badge: Skip" now actually hides your badge. With cross-shard teammates on (the
    default), your own badge used to reappear as a dimmed "far" badge — your record arrives over the
    cross-shard broadcast and the skip only applied to the local pass. Now suppressed on both
[/list]

[b]Settings (each player picks their own)[/b]
[list]
[*] HUD Layout: Horizontal / Vertical
[*] HUD Position: Minimap / Minimap XL / Standard
[*] Show Your Own Badge: Show / Skip
[*] Hunger/Sanity Sub-gauges: Show / Hide
[*] Show Cross-Shard Teammates: Show / Hide (other-shard or out-of-view teammates; on by default)
[*] HP Number: Always / On hover
[*] Low-HP Alert: Off / 40% / 25% / 15% (pulse the badge border red below this % of max HP)
[*] Teammate avatar: Off / Corner / Centred head (show each teammate's character; default Centred head)
[*] Colour Teammate Names: On / Off (tint each name in that player's own colour; default on)
[/list]

[b]Note[/b] — this is a server mod: install it on your dedicated server (or enable
when hosting) and connecting players download it automatically to play.

[b]Tip[/b] — the settings above are per-player CLIENT options. To change your own
(layout, low-HP alert, etc.) you must also SUBSCRIBE to this mod on the Workshop so it
shows up in your Mods -> PartyHud 2026 -> Configure. If you only got it by joining a
server, you can still play and see it, but with the default settings (no Configure entry).

[b]Source[/b]: https://github.com/iblislin/DST-PartyHud
Original PartyHUD by brianchenito, released into the public domain (Unlicense).
Thanks for the original work!
```

## Steam Workshop 說明 — 繁體中文(可直接複製,Steam BBCode)

```
[b]PartyHud 2026[/b]

直接在 HUD 上看到隊友的狀態 —— 每位玩家一個徽章,顯示名字、目前 HP、
飢餓與理智,並提示著火與溫度(過熱/失溫),隨時掌握誰快不行了。

這是經典 mod [b]PartyHUD[/b](原作者 brianchenito)的社群更新版,
重新移植以支援現版的 Don't Starve Together。

[b]更新內容[/b]
[list]
[*] 支援現版 DST(原版自 2016 年後未更新)
[*] 修正玩家離線造成的專用伺服器 crash,以及進洞穴 / shard 遷移的 crash
[*] 修正血條不顯示的問題(重新對接現版 badge UI)
[*] 新增[b]垂直[/b]排列,並保留經典的[b]水平[/b]排列
[*] 排列與位置改為[b]每位玩家可自訂[/b](Mods -> PartyHud 2026 -> Configure)
[*] 相容 minimap mod 的位置預設(Minimap / Minimap XL / Standard)
[/list]

[b]2026.6 新增 —— 更豐富的狀態[/b]
[list]
[*] 主 HP 環下方新增飢餓、理智小子環;數字為遊戲內真實絕對值(滑鼠移上去看數字)
[*] 著火 / 過熱 / 失溫以 HP 環上的顏色脈動提示(橘 / 紅 / 青)
[*] 理智速率箭頭(上升/下降),與遊戲原生條一致
[*] 垂直排列依螢幕高度自動換欄、視窗縮放會重排,並避開地圖(M)按鈕
[*] 新選項:顯示自己的徽章、飢餓/理智子環(可隱藏為精簡的純 HP 徽章)
[/list]

[b]2026.7 新增 —— 上限懲罰與受傷提示[/b]
[list]
[*] 主環顯示最大 HP / 理智的「上限懲罰」(無盡模式復活造成),以變暗的弧形呈現,與遊戲原生徽章一致
[*] 隊友因著火 / 過熱 / 失溫而掉血時,HP 環會顯示向下箭頭,與顏色脈動同時出現
[*] 隊友睡覺時,理智箭頭會正確顯示為上升
[*] 強化幽靈/死亡狀態,以及加入 / 離開 / 進洞穴遷移的處理
[/list]

[b]2026.8 新增 —— 跨 shard 隊友與排版優化[/b]
[list]
[*] 看得到另一個 shard(洞穴 <-> 地面)的隊友,以及同 shard 但超出網路範圍的隊友 —— 這些人以前
    完全沒有徽章。狀態透過恆連線的廣播中繼,約每秒更新兩次
[*] 遠方隊友以變暗呈現並標示位置:另一 shard 標「Caves」/「Surface」,同 shard 超出範圍標「far」。
    視野內的本地隊友永遠優先,所以不會重複顯示
[*] 垂直排列在縮放 / 小視窗下的欄數現在穩定(納入 HUD 比例縮放計算)
[*] 只有最右欄保留地圖(M)按鈕空間,其餘欄位向下延伸
[*] 避開遊戲原生 UI —— 閃開雨量(潮濕)計與角色狀態徽章(Wendy 的 Abigail、Wigfrid 的靈感);
    死亡玩家的骷髏圖示現在置中
[*] 背包感知:開啟側邊背包時整個 HUD 左移讓位,或在「整合式背包」選項下保留底部空間;
    開關背包、裝備/卸下、甚至交換背包都會即時反應
[/list]

[b]2026.9 修正[/b]
[list]
[*] 修正在有洞穴(雙 shard)的伺服器上、玩家加入時造成的伺服器 crash(2026.8 的內部變更用到了
    mod 沙箱環境沒有的函式)。無玩法/視覺變更;若你在 2026.8 開了洞穴,請更新到 2026.9。
[/list]

[b]2026.10 新增 —— 低 HP 警示[/b]
[list]
[*] 隊友 HP 低於你設定的門檻時,徽章邊框會以柔和的紅色脈動,讓「誰快死了」一眼就看到 ——
    這是其他 DST 隊友 HUD 都沒有的提示
[*] 新選項 Low-HP Alert(低 HP 警示):Off / 40% / 25% / 15%(占其最大 HP 的百分比;預設 25%)
[*] 與著火/過熱/失溫警示並存(不同元件,所以又低血又著火會同時顯示),遠距 / 跨-shard 徽章也會脈動
[/list]

[b]2026.12 新增 —— 隊友頭像與名字配色[/b]
[list]
[*] 每個徽章可顯示隊友的角色頭像:角落的小頭像,或在 HP 環中央的動畫角色臉(HP 數字改為滑鼠移上才顯示,
    讓臉不被遮住)。頭像會反映每位玩家所選的角色造型(skin),遠距 / 跨-shard 的隊友也會顯示其造型
[*] 新選項 Teammate avatar(隊友頭像):Off / Corner(角落)/ Centred head(置中頭像;預設)。置中樣式下,
    當隊友出現著火 / 過熱 / 失溫 / HP 速率箭頭時,徽章會暫時翻成角落樣式,讓箭頭不被臉擋住
[*] 新選項 Colour Teammate Names(隊友名字配色)—— 將每個名字染成該玩家自己的顏色(預設開啟)
[*] 修正:遠距 / 跨-shard 隊友靜止不動時,其徽章可能消失(資料 staleness 誤判);現在徽章會保持顯示
[/list]

[b]2026.13 修正[/b]
[list]
[*] 「Show Your Own Badge:Skip(隱藏自己的徽章)」現在真的會隱藏。開啟跨-shard 隊友(預設)時,你自己的
    徽章會以變暗的「far」樣式重新出現 —— 你的資料會透過跨-shard 廣播傳來,而原本的隱藏只套用在本地那一輪。
    現在兩條路徑都會抑制。若你保持顯示自己的徽章則無變化
[/list]

[b]設定(每位玩家各自選擇)[/b]
[list]
[*] HUD Layout(排列):Horizontal(水平)/ Vertical(垂直)
[*] HUD Position(位置):Minimap / Minimap XL / Standard
[*] Show Your Own Badge(顯示自己):Show / Skip
[*] Hunger/Sanity Sub-gauges(飢餓/理智子環):Show / Hide
[*] Show Cross-Shard Teammates(顯示跨 shard 隊友):Show / Hide(另一 shard 或超出視野的隊友;預設開啟)
[*] HP Number(HP 數字):Always(總是)/ On hover(滑鼠移上)
[*] Low-HP Alert(低 HP 警示):Off / 40% / 25% / 15%(低於最大 HP 此百分比時,徽章邊框紅色脈動)
[*] Teammate avatar(隊友頭像):Off / Corner(角落)/ Centred head(置中頭像;顯示每位隊友的角色,預設置中頭像)
[*] Colour Teammate Names(隊友名字配色):On / Off(將每個名字染成該玩家自己的顏色;預設開啟)
[/list]

[b]注意[/b] —— 這是伺服器端 mod:安裝在你的專用伺服器(或開房時啟用),
連線的玩家會自動下載即可遊玩。

[b]提示[/b] —— 上面的設定是「每位玩家」的 CLIENT 選項。要改自己的(排列、低 HP 警示等),
你還必須在 Workshop 上「訂閱」這個 mod,它才會出現在你的 Mods -> PartyHud 2026 -> Configure
裡。若你只是連伺服器自動下載的,仍可遊玩並看到 HUD,但只能用預設值(沒有 Configure 入口)。

[b]原始碼[/b]:https://github.com/iblislin/DST-PartyHud
原版 PartyHUD 作者 brianchenito,已釋出至公有領域(Unlicense)。感謝原作!
```
