# Bundled fixture library

638 fixture definitions generated from the [Open Fixture Library](https://open-fixture-library.org) project (commit `6c52a67c9639`).

Each definition was converted to this app's `FixtureProfile` format by `tools/build_fixture_library.gd` (which calls the same `FixtureImport.from_ofl` used for manual imports). Regenerate with:

```
git clone --depth 1 https://github.com/OpenLightingProject/open-fixture-library
godot --headless --script tools/build_fixture_library.gd -- open-fixture-library
```

## Licence

OFL fixture data is published under the MIT licence for the schema/tooling and, per fixture, CC0-1.0 or CC-BY-SA-4.0 for the data. The upstream `LICENSE` is kept here as `OFL-LICENSE.txt`. Fixture authors are credited in `index.json` (`authors` per entry).
