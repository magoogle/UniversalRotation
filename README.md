# Universal Rotation

A dynamic, priority-based spell rotation engine for Diablo IV. Automatically selects and casts spells based on configurable priorities, targeting modes, buff requirements, resource thresholds, and combo chains.

## Features

- **Priority-Based Rotation** — Spells are cast in configurable priority order (1 = highest). One cast per frame with global cooldown enforcement.
- **5 Targeting Modes** — Priority (Boss → Elite → Champion → Closest), Closest, Lowest HP, Highest HP, and Cleave Center (most enemies in radius).
- **Combo Chains** — Casting spell A can temporarily boost spell B's priority for a configurable duration, enabling skill combos.
- **Buff Requirements** — Restrict spells to only cast when the player has a specific buff with a minimum stack count.
- **Resource Conditions** — Cast spells only when primary resource is above or below a configurable threshold.
- **Multi-Charge Tracking** — Supports spells with multiple charges and independent cooldown tracking per charge.
- **Per-Class Profiles** — Automatic save/load of spell configurations per character class (JSON format). Includes manual import/export.
- **On-Screen Overlay** — Displays equipped spells in priority order, color-coded by status (green = ready, yellow = cooldown, red = unavailable).
- **Auto Movement** — Moves toward melee targets that are out of range before casting.

## Project Structure

```
UniversalRotation/
├── main.lua                  # Entry point, main loop, profile management
├── gui.lua                   # In-game menu UI rendering
├── core/
│   ├── rotation_engine.lua   # Core combat loop & spell execution
│   ├── spell_config.lua      # Per-spell configuration & UI controls
│   ├── spell_tracker.lua     # Cooldown & charge tracking
│   ├── target_selector.lua   # Enemy selection algorithms
│   ├── buff_provider.lua     # Buff detection & management
│   └── profile_io.lua        # JSON serialization (pure Lua)
└── *.json                    # Class profiles (barbarian, paladin, etc.)
```

## Configuration

### Global Settings

| Setting | Range | Default | Description |
|---------|-------|---------|-------------|
| Enable | Toggle | Off | Master on/off switch |
| Toggle Key | Keybind | Unbound | Optional keybind to toggle rotation |
| Scan Range | 5–30 yds | 16.0 | Enemy detection radius |
| Animation Delay | 0.0–0.5s | 0.05 | Minimum delay between casts |
| Debug Mode | Toggle | Off | Enables console logging |
| Overlay | Toggle | On | Show on-screen spell status |
| Overlay X / Y | 0–3000 px | 20 / 12 | Overlay screen position |
| Show Buff List | Toggle | Off | Display active buffs on overlay |

### Per-Spell Settings

| Setting | Range | Description |
|---------|-------|-------------|
| Enable | Toggle | Include spell in rotation |
| Priority | 1–10 | Cast order (lower = sooner) |
| Spell Type | Auto / Melee / Ranged | Attack style |
| Spell Range | 1.0–30.0 yds | Maximum cast distance |
| AOE Range | 1.0–20.0 yds | Radius for enemy count checks |
| Target Mode | 5 modes | Target selection algorithm |
| Self Cast | Toggle | Cast at player position |
| Min Enemies | 0–15 | Minimum nearby enemies to trigger |
| Elite Only | Toggle | Only cast on bosses/elites |
| Boss Only | Toggle | Only cast on bosses |
| Require Buff | Toggle | Gate cast behind a buff condition |
| Buff / Min Stacks | Dropdown / 1–50 | Which buff and minimum stack count |
| Resource Condition | Toggle | Gate cast behind resource check |
| Resource Mode | Below % / Above % | Resource threshold direction |
| Resource Threshold | 1–100% | Resource percentage trigger point |
| Combo Chain | Toggle | Enable chaining to another spell |
| Chain Target / Boost | Dropdown / 1–9 | Which spell to boost and by how much |
| Boost Duration | 0.5–10.0s | How long the priority boost lasts |
| Min Cooldown | 0.0–5.0s | Forced cooldown between casts |
| Charges | 1–5 | Number of charges for multi-charge spells |

## Supported Classes

Profiles are auto-detected and loaded by class ID:

| ID | Class |
|----|-------|
| 0 | Sorcerer |
| 1 | Barbarian |
| 2 | Druid |
| 3 | Rogue |
| 6 | Necromancer |
| 9 | Paladin |

Profiles are saved as `universal_rotation_<class>.json` and persist all spell and global settings.

## How It Works

1. **Spell Scanning** — Every 2 seconds, the equipped spell bar is scanned and spell configurations are loaded or created.
2. **Rotation Tick** — Each frame, spells are sorted by effective priority (accounting for active combo boosts), preconditions are validated (cooldowns, buffs, resources, enemy counts), a target is selected, and the highest-priority ready spell is cast.
3. **Combo Chains** — After casting, if a combo chain is configured, the target spell's effective priority is temporarily reduced (boosted) for the configured duration.
4. **Profile Persistence** — On class change, the current profile is saved and the new class profile is loaded. Profiles can also be manually imported/exported via the GUI.

## License

This project is provided as-is for personal use.
