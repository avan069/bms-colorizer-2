# BMS-COLORIZER-2
v0.2.0 (2026-02-03)

## What it does
Colors human-controlled BMS aircraft by flight in Tacview.

- Human detection: objects with a non-empty "Pilot" property.
- Flight grouping: uses "CallSign" formatted like Viper14 / Dog11 / Nightwing53
  (prefix + flight digit + ship digit).
- Colors: assigns a per-flight color from the `builtInFlightColors` list in `main.lua`.
  If there are more flights than colors, it cycles back to the top of the list.

## Install
1) **Copy this entire folder to:**  
  `\Program Files (x86)\Tacview\AddOns\bms-colorizer-2\`

2) **Copy Data-ObjectsColors.xml from this folder to:**  
  `\ProgramData\Tacview\Data\Xml`

3) **Enable the add-on in Tacview:**  
  Add Ons (gear icon) -> Enable/Disable Add Ons -> BMS Colorizer 2

## Colors / palette setup
This add-on writes `Color=<value>` into the ACMI for each flight. The colors it selects from are
defined in Data-ObjectsColors.xml, which modifies the default red and blue, and adds additional colors.

If you have color deficiency or don't like my choices, you can modify them. 
1) Open Tacview's Data-ObjectsColors.xml:
   `\ProgramData\Tacview\Data\XmlData-ObjectsColors.xml`

2) Modify `<Color ID="PXX">...</Color>` entries. "Side" is the most prominent property.

## Use
In Tacview, open a BMS ACMI and use:
  Add Ons (gear icon) -> BMS Colorizer 2 -> Assign Colors Now. (By default, assignment will happen automatically on file load when the addon is installed.) You *will* notice a significant slowdown while the addon processes large .acmi files.

  Various self-explanatory options exist in the BMS Colorizer 2 menu.

## Options (GUI)
Tacview add-ons have limited UI; configuration is done via menu options:

- Auto-Assign On Load: recolor automatically once per loaded ACMI.
- Show Legend Overlay: draws a small on-screen legend with flight->palette mapping.
- Fixed-Wing Only: only color Air+FixedWing objects (recommended).

## Notes / troubleshooting
- If no change to colors: your ACMI likely has no "Pilot" values.
- Human flights are all grey: your `Color` values may not exist in Tacview's colors database, **see 'Install' step 2!**
