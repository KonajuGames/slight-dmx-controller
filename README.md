# Godot DMX Lighting Controller

A ready-to-run Godot 4 project with a GUI for controlling DMX lighting
fixtures over **Art-Net** (DMX-over-Ethernet). Art-Net is used here because
it's the one DMX transport Godot can speak natively — it's just UDP packets,
so no native plugin or GDExtension is required.

## What's included

- `project.godot` — project config, registers `artnet_sender.gd` as the
  `ArtNet` autoload singleton.
- `artnet_universe.gd` — the `ArtNetUniverse` class: one universe's
  512-channel buffer plus its own UDP socket and target. Builds and sends
  `ArtDMX` packets, optionally scaled by the grand master.
- `artnet_sender.gd` — the `ArtNet` autoload: manages one `ArtNetUniverse`
  per universe slot (up to 8), a global grand master, and `send_all()`.
- `main.tscn` — a single root `Control` node with the GUI script attached.
- `dmx_controller.gd` — the shell: a top bar (grand master, Sending,
  add/remove universe, whole-show + preset save/load) above a
  `TabContainer` with one universe panel per tab, plus the shared
  fixture-profile list and the New Profile dialog.
- `universe_panel.gd` — the `UniversePanel` class: one universe's tab —
  its connection settings, quick RGB row, blackout/full, and fixture
  patch with purpose-built per-fixture controls.
- `cue.gd` — the `Cue` class: a stored look (every universe's non-zero
  channels) plus split fade-in / fade-out times; captures from and
  renders back to the live buffers.
- `cue_list_panel.gd` — the `CueListPanel` class: the playback side —
  an ordered cue list with GO / Back / Halt, record / update / delete,
  and the crossfade engine driven from `ArtNet`.
- `fixture_profile.gd` — the `FixtureProfile` class: one or more DMX
  *modes*, each an ordered channel list. Every channel has a role
  (`DIMMER`, `RED`, `PAN`, ...) plus a default/home value, min/max
  limits, a 16-bit `fine` flag, and optional named value ranges. Ships a
  handful of built-in profiles (including a multi-mode moving head) and
  JSON (de)serialization that still reads the old single-list format.

## Universes

The window is a tab per Art-Net universe. **Add Universe** / **Remove
Universe** in the top bar manage the list (1–8 universes); each tab has
its own IP, port, and Art-Net universe number (several tabs may target
the same number on different IPs), its own fixture patch, and its own
512-channel buffer. New universes are numbered to the first free Art-Net
number.

Global controls live in the top bar:

- **Grand Master** — one 0–255 fader that scales *every* universe's
  output on send (non-destructive: the per-channel values you dialed
  aren't lost when you pull it down and back up).
- **Sending** — toggles the ~30 Hz refresh stream for all universes.
- **Blackout All** — zeroes every universe.
- **Save/Load Show** — one `user://dmx_show.json` covering every
  universe's connection settings and fixture patch. A legacy
  single-universe patch file (a bare fixtures array) still loads, as
  universe 1.
- **Save/Load Preset** — one `user://dmx_preset.json` with every
  universe's live DMX buffer (non-zero channels only). A legacy flat
  `{channel: value}` preset still loads, into universe 1. A preset wider
  than the current show adds the missing universes.

## Cue list

The left-hand panel is the playback side of the console — an ordered list
of **cues**, each a stored look plus fade timing. Stepping through them
crossfades the whole rig.

- **Record Cue** captures the current live output of *every* universe as
  a new cue (inserted after the selected one, or at the end). So dial a
  look with the fixture controls, set **New cue fade**, and record.
- **GO** (or the **spacebar**) fires the next cue: every universe
  crossfades from whatever it's outputting now to the cue's stored
  levels. Channels rising use the cue's *fade up* time, channels falling
  use *fade down*. Cues are **non-tracking** — a channel the cue doesn't
  store fades to 0.
- **Back** fades to the previous cue; **Halt** freezes a running fade
  where it is.
- Select a cue to edit its **label** and **fade up / down** seconds
  inline. **Update** overwrites the selected cue with the current live
  output; **Duplicate** and **Delete** do what they say.
- Cues (and which one is live) are saved inside the show file.

While a fade is running it owns the output — moving a fixture control
mid-fade is overwritten until the fade lands. **Blackout All**, loading a
preset, or loading a show cancels any running fade.

## Fixture profiles

Instead of only controlling raw DMX channels, you can patch **fixtures**:
a profile (what kind of light it is) plus a start channel (where it sits
in that universe).

**Built-in profiles**: Dimmer (1ch), RGB (3ch), RGBW (4ch), RGBAW (5ch),
a 7-channel Moving Head RGBW Pan/Tilt, and a multi-mode Moving Head Spot
(8ch and 14ch/16-bit personalities showing off fine channels, value
slots, and defaults). Real fixtures vary a lot in channel order — always
check the fixture's own DMX chart before relying on one of these for a
physical light; the moving-head profiles in particular are just
illustrative starting points.

Each channel in a profile carries more than a role:

- **default** — the home value the fixture snaps to when first patched
  and whenever you click its **Home** button.
- **min / max** — clamp limits, so a channel's control can't leave its
  usable range.
- **fine** — marks a channel as the 16-bit LSB partner of the channel
  right before it (Pan + Pan Fine, Tilt + Tilt Fine, Dimmer + Dimmer
  Fine, ...).
- **ranges** — named value slots for wheels (gobo, colour), e.g.
  `0-9 Open, 10-19 Red, 20-29 Orange`.

Profiles can also have **multiple modes** (personalities) — the same
fixture as an 8-channel and a 14-channel layout, say. Pick the mode in
the **Mode** dropdown when patching.

**Patching a fixture**: in the "Fixture Patch" row, pick a profile and
mode, optionally name it, set its start channel, and click **Add
Fixture**. Its panel appears below with the right controls automatically:
- A complete Red/Green/Blue trio becomes one colour picker.
- A channel + its fine partner become one high-resolution (0–65535)
  slider that splits across the two DMX channels on output.
- A channel with named ranges becomes a slot dropdown plus a trim slider
  (they stay in sync — moving the slider re-selects the slot it lands in).
- Every other channel gets its own small slider, clamped to min/max.
- A fixture with colour/white channels but **no DIMMER channel of its
  own** also gets a **virtual dimmer**: a per-fixture intensity master
  that scales its Red/Green/Blue/White/Amber/UV output on the way to the
  wire, so you can fade the fixture without disturbing the colour you
  set. It homes to full (so a homed fixture acts like one whose real
  dimmer is open).
- **Home** resets every control in that fixture to its channel defaults;
  **Remove** deletes it.

**Custom profiles**: click **New Profile...** to open a dialog where you
name the profile, add one or more modes, and add channels one at a time.
Each channel row has a label, a role dropdown, `d` / `min` / `max`
spinners, a `16-bit` checkbox, and a free-text ranges field
(`0-9:Open, 10-19:Red`). Saving writes a JSON file to
`user://fixture_profiles/` and adds it to the profile picker immediately
— no restart needed.

Custom profiles are shared across every universe tab and persist in
`user://fixture_profiles/`. The fixture list itself is saved as part of
the whole-show file (see **Save/Load Show** above), including each
fixture's full profile definition, so a show is portable even if a custom
profile file is later deleted. Older single-mode profile JSON still loads
— a bare channel list is read as one "Default" mode.

There's no raw per-channel slider list — all control happens through
patched fixtures (plus the quick RGB row for a one-off trio of channels).
Loading a preset updates the live output immediately but won't visually
move any fixture panel's sliders/pickers, since those are write-only
controls rather than a live readout of the buffer.

## Running it

1. Open the folder in Godot 4.4+ (`Project > Import`, point at
   `project.godot`).
2. Press Play (F5). The main scene builds its own UI at runtime.
3. On the **Universe 1** tab, set the **IP / Port / Art-Net universe** for
   your receiver and click **Apply Connection**. Default is
   `127.0.0.1:6454`, Art-Net universe 0. Add more universe tabs from the
   top bar as needed.
4. Move any fixture control — it's sent to that universe's target roughly
   30 times a second while **Sending** is checked, matching how real DMX
   gear expects a continuous refresh stream rather than one-off packets.
5. Dial a look, click **Record Cue**, repeat for a few looks, then step
   the show with **GO** (or the spacebar).

The window is freely resizable (down to 720×480). Toolbars, the
connection/patch rows, and each fixture's bank of sliders are laid out in
wrapping rows, so controls that don't fit the current width flow onto the
next line instead of running off the right edge; the fixture list scrolls
vertically only.

### Testing without real hardware

You don't need physical lighting to try this out:

- **QLC+** (free, open source) can receive Art-Net and show live DMX
  values / drive a virtual console — good for confirming packets arrive
  correctly before connecting real fixtures.
- Any Art-Net monitor/sniffer will show the same.

### Going to real fixtures

Point the IP at an Art-Net-to-DMX gateway/node (e.g. an ENTTEC ODE,
a DIY ESP32 Art-Net node, or a lighting desk's Art-Net input) on your
network, set the matching universe, and the gateway converts the Ethernet
packets to a physical DMX512 signal for your fixtures.

## Extending it

- **sACN (E1.31)** instead of Art-Net: same idea, different packet format
  and multicast address — swap out `ArtNetUniverse.send()` for an
  sACN-formatted packet.
- **Direct USB DMX interfaces** (e.g. ENTTEC USB Pro) instead of a network
  gateway: these need serial/USB access, which Godot doesn't expose
  natively — you'd need a GDExtension wrapping a serial library, since
  pure GDScript can't talk to USB DMX widgets directly.
- **Fixture profiles**: already implemented — `FixtureProfile` carries
  per-mode channel lists with roles, defaults, min/max, 16-bit fine
  pairs, and named value ranges, and the GUI generates purpose-built
  controls per fixture (including a virtual dimmer for fixtures with no
  dimmer channel). Room to grow: colour-wheel/gobo *images* in the
  dropdown, importing GDTF / Open Fixture Library definitions.
- **Cues/timeline**: the cue list (`cue.gd`, `cue_list_panel.gd`) does
  split-time crossfades across every universe. Room to grow: cue-to-cue
  auto-follow / wait times, a fade progress bar, effects/chases, MIDI or
  OSC GO triggers, tracking (only store what a cue changes).
