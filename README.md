# PartyHud 2026

A modernized fork of [PartyHUD](https://github.com/brianchenito/PartyHud) by **brianchenito** — shows every player's health right on your HUD, updated to work on current *Don't Starve Together*.

- **Source:** https://github.com/iblislin/DST-PartyHud
- **Steam Workshop:** _(add link after publishing)_

![PartyHud 2026 — vertical layout preview](preview.jpg)

## What's new in 2026
- Works on current DST (the original was last updated in 2016)
- Fixed a dedicated-server crash that triggered when a player disconnected
- Fixed the invisible health badge (re-ported to the current `Badge` widget; build `health` → `status_health`)
- New **Vertical** layout, plus the classic **Horizontal** row
- Layout & position are now **per-player** settings (`client = true`)
- Minimap-friendly position presets; vertical anchor follows the position setting

## Install (server mod)
Subscribe on the Workshop, **or** place this folder into your server's `mods/` as `partyhud` and enable it in each shard's `modoverrides.lua`:
```lua
["partyhud"] = { enabled = true }
```
Connecting players download it automatically. _(If you grab a GitHub source archive, rename the extracted folder to `partyhud`.)_

## Settings (each player chooses their own)
- **HUD Layout:** Horizontal / Vertical
- **HUD Position:** Minimap / Minimap XL / Standard

## Credits & License
Original PartyHUD by **brianchenito**, released into the public domain under [The Unlicense](LICENSE). Attribution is not required, but kept here with thanks for the original work.

---

## Steam Workshop description — English (copy-paste, Steam BBCode)

```
[b]PartyHud 2026[/b]

See your teammates' health right on your HUD — a badge showing each player's
name and current HP, so you always know who needs help.

A community update of the classic [b]PartyHUD[/b] by brianchenito, modernized
to work on current Don't Starve Together builds.

[b]What's new[/b]
[list]
[*] Works on current DST (the original was last updated in 2016)
[*] Fixed a dedicated-server crash that triggered when a player disconnected
[*] Fixed the health badge not showing (re-ported to the current badge UI)
[*] New [b]Vertical[/b] layout, plus the classic [b]Horizontal[/b] row
[*] Layout & position are now [b]per-player[/b] settings (Mods -> PartyHud 2026 -> Configure)
[*] Minimap-friendly position presets (Minimap / Minimap XL / Standard)
[/list]

[b]Settings (each player picks their own)[/b]
[list]
[*] HUD Layout: Horizontal / Vertical
[*] HUD Position: Minimap / Minimap XL / Standard
[/list]

[b]Note[/b] — this is a server mod: install it on your dedicated server (or enable
when hosting) and connecting players download it automatically.

[b]Source[/b]: https://github.com/iblislin/DST-PartyHud
Original PartyHUD by brianchenito, released into the public domain (Unlicense).
Thanks for the original work!
```

## Steam Workshop 說明 — 繁體中文(可直接複製,Steam BBCode)

```
[b]PartyHud 2026[/b]

直接在 HUD 上看到隊友的血量 —— 每位玩家一個血條,顯示名字與目前 HP,
隨時掌握誰快不行了。

這是經典 mod [b]PartyHUD[/b](原作者 brianchenito)的社群更新版,
重新移植以支援現版的 Don't Starve Together。

[b]更新內容[/b]
[list]
[*] 支援現版 DST(原版自 2016 年後未更新)
[*] 修正玩家離線時造成的專用伺服器 crash
[*] 修正血條不顯示的問題(重新對接現版 badge UI)
[*] 新增[b]垂直[/b]排列,並保留經典的[b]水平[/b]排列
[*] 排列與位置改為[b]每位玩家可自訂[/b](Mods -> PartyHud 2026 -> Configure)
[*] 相容 minimap mod 的位置預設(Minimap / Minimap XL / Standard)
[/list]

[b]設定(每位玩家各自選擇)[/b]
[list]
[*] HUD Layout(排列):Horizontal(水平)/ Vertical(垂直)
[*] HUD Position(位置):Minimap / Minimap XL / Standard
[/list]

[b]注意[/b] —— 這是伺服器端 mod:安裝在你的專用伺服器(或開房時啟用),
連線的玩家會自動下載。

[b]原始碼[/b]:https://github.com/iblislin/DST-PartyHud
原版 PartyHUD 作者 brianchenito,已釋出至公有領域(Unlicense)。感謝原作!
```
