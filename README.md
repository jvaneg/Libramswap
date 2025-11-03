# LibramSwap
Swaps to the correct libram before casting Paladin spells. Just put them in your bag and cast!

Supports casts via the action bar, macros, the spellbook, and all addons I've seen so far (but make an issue if you find one that doesn't work).

## Commands
All commands support three aliases: `/libramswap`, `/lswap`, or `/ls`

### Basic Commands
- `/ls` - Toggle LibramSwap on/off
- `/ls on` - Enable LibramSwap
- `/ls off` - Disable LibramSwap
- `/ls spam` - Toggle swap confirmation messages
- `/ls status` - Show current settings
- `/ls help` - Show command list

### Libram Selection

Some spells have multiple libram options. You can choose which one to use:

#### Consecration
- `/ls consecration faithful` or `/ls c f` - Use **Libram of the Faithful** (default)
- `/ls consecration farraki` or `/ls c z` - Use **Libram of the Farraki Zealot**

#### Holy Strike
- `/ls holystrike eternal` or `/ls hs e` - Use **Libram of the Eternal Tower** (default)
- `/ls holystrike radiance` or `/ls hs r` - Use **Libram of Radiance**

## Supported Spells & Librams

| Spell | Libram |
|-------|--------|
| Consecration | Libram of the Faithful / Farraki Zealot |
| Holy Shield | Libram of the Dreamguard |
| Holy Light | Libram of Radiance |
| Flash of Light | Libram of Light (fallback: Divinity) |
| Cleanse | Libram of Grace |
| Hammer of Justice | Libram of the Justicar |
| Hand of Freedom | Libram of the Resolute |
| Crusader Strike | Libram of the Eternal Tower |
| Holy Strike | Libram of the Eternal Tower / Radiance |
| Judgement | Libram of Final Judgement (only at ≤35% target HP) |
| Seal of Wisdom/Light/Justice/Command/Righteousness | Libram of Hope |
| Seal of the Crusader | Libram of Fervor |
| Devotion Aura | Libram of Truth |
| All Blessings | Libram of Veracity |
