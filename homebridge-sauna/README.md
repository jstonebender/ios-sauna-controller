# homebridge-sauna

HomeKit control for a **Finnmark FD-5** infrared sauna, via the
[saunad](https://github.com/jstonebender/ios-sauna-controller/tree/main/saunad) local
bridge. Part of the [IOS Sauna Controller](https://github.com/jstonebender/ios-sauna-controller)
project (a fork of [ember](https://github.com/mattsmcnulty/ember)).

Adds three accessories to the Home app:

| Accessory | Service | What it does |
|---|---|---|
| **Sauna** | Thermostat | Live temperature, target dial (86–170 °F), heat on/off. "Hey Siri, set the sauna to 155 degrees." Heat mirrors the app's Start (powers the cabin on and heats); Off mirrors Stop (full off — power and heater). |
| **Sauna Lights** | Lightbulb (+ linked "Rainbow" switch) | Interior lights on/off and color. The sauna supports 8 solid colors, so any pick on the HomeKit color wheel **snaps to the nearest real color** (low saturation = white). The Rainbow switch runs the sauna's "Scroll" color cycle. The lights only respond while the cabin is powered on. |
| **Sauna Power** | Switch | The independent cabin-power toggle. Off = full stop (power + heater), like the app's Stop. |

## Requirements

- A running [saunad](https://github.com/jstonebender/ios-sauna-controller/tree/main/saunad)
  reachable from the Homebridge host (same machine is ideal: `http://localhost:8765`)
- Homebridge ≥ 1.8, Node ≥ 18

## Install

Not published to npm (single-user project) — install from a packed tarball:

```bash
cd homebridge-sauna
npm install && npm run build && npm pack     # → homebridge-sauna-x.y.z.tgz
sudo npm -g install ./homebridge-sauna-*.tgz # on the Homebridge host
```

## Config

Via the Homebridge UI (the plugin ships a settings form), or in `config.json`:

```json
{
  "platform": "FinnmarkSauna",
  "name": "Sauna",
  "baseUrl": "http://localhost:8765",
  "apiKey": "<saunad server.apiKey>",
  "pollSeconds": 5,
  "exposePowerSwitch": true,
  "exposeLights": true,
  "exposeRainbowSwitch": true
}
```

## ⚠️ Safety

This exposes a **heating appliance** to HomeKit automations — an automation can turn the
heater on with nobody home. Set `server.heaterMaxOnMinutes` in saunad's `options.json`
(e.g. `180`) so the bridge force-stops a heater left on too long. The plugin deliberately
does not expose the sauna's session timer.

## Notes

- Zero runtime dependencies; talks plain HTTP to saunad (which owns the sauna's single
  Tuya LAN socket — this plugin is just another client of the bridge, alongside the iOS app).
- HomeKit is Celsius-internal; the plugin widens the thermostat's range
  (default HomeKit thermostats stop at 38 °C / 100 °F) and keeps the dial stable on a
  0.5 °C grid while the device itself works in whole °F.
- The FD-5 light is a single enum (a color, "Scroll", or "Off") and only changes while
  the cabin is powered on — a light toggle sent with the sauna off briefly shows
  "No Response" and reverts on the next poll.
