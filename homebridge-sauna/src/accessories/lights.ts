import { PlatformAccessory, Service } from 'homebridge';

import { AccessoryHandler, SaunaPlatform } from '../platform';
import { ControlBody, SaunadState } from '../client';
import { nearestSolid, solidFor } from '../colors';

/** Interior lights (Tuya DP111) as a color bulb whose picks snap to the sauna's real
 *  chroma solids, plus an optional linked "Rainbow" switch for the "Scroll" cycle.
 *
 *  The FD-5 light is a single enum: a color name, "Scroll", or "Off". There is no
 *  separate on/off DP, so "bulb on" means a color/Scroll is selected and "bulb off"
 *  sends "Off". The sauna only accepts a light change while powered ON — saunad rejects
 *  it otherwise (HTTP 400), so a toggle made with the cabin off surfaces as a brief
 *  "No Response" and the next poll restores the real (Off) state. */
export class SaunaLights implements AccessoryHandler {
  private readonly bulb: Service;
  private readonly rainbow?: Service;

  private on = false;
  private hue = 0;
  private sat = 0;
  private cycleOn = false;
  private lastSolid = 'White'; // remember a color so a plain On toggle restores one

  // The Home app fires Hue/Saturation (and sometimes On) as separate set events
  // within milliseconds — coalesce them into ONE /control call.
  private pending: { hue?: number; sat?: number } = {};
  private flushTimer?: NodeJS.Timeout;

  constructor(
    private readonly platform: SaunaPlatform,
    accessory: PlatformAccessory,
  ) {
    const { Service, Characteristic } = platform;

    this.bulb = accessory.getService(Service.Lightbulb) ?? accessory.addService(Service.Lightbulb);
    this.bulb.setCharacteristic(Characteristic.Name, accessory.displayName);
    this.bulb.setPrimaryService(true);

    this.bulb
      .getCharacteristic(Characteristic.On)
      .onGet(() => {
        this.platform.assertReachable();
        return this.on;
      })
      .onSet(async (value) => {
        // On → restore the last solid color; Off → the light's "Off" value.
        await this.platform.control({ chromoColor: (value as boolean) ? this.lastSolid : 'Off' });
      });

    // The color-picker UX assumes a Brightness characteristic; the hardware has none.
    // Report 100 always; a 0 set means "off", anything else is ignored.
    this.bulb
      .getCharacteristic(Characteristic.Brightness)
      .onGet(() => 100)
      .onSet(async (value) => {
        if ((value as number) === 0) {
          await this.platform.control({ chromoColor: 'Off' });
        } else {
          setTimeout(() => this.bulb.updateCharacteristic(Characteristic.Brightness, 100), 100);
        }
      });

    this.bulb
      .getCharacteristic(Characteristic.Hue)
      .onGet(() => {
        this.platform.assertReachable();
        return this.hue;
      })
      .onSet((value) => this.queueColor({ hue: value as number }));

    this.bulb
      .getCharacteristic(Characteristic.Saturation)
      .onGet(() => {
        this.platform.assertReachable();
        return this.sat;
      })
      .onSet((value) => this.queueColor({ sat: value as number }));

    if (platform.config.exposeRainbowSwitch ?? true) {
      this.rainbow =
        accessory.getServiceById(Service.Switch, 'rainbow') ??
        accessory.addService(Service.Switch, 'Rainbow', 'rainbow');
      this.rainbow.addOptionalCharacteristic(Characteristic.ConfiguredName);
      this.rainbow.setCharacteristic(Characteristic.ConfiguredName, 'Rainbow');
      this.bulb.addLinkedService(this.rainbow);

      this.rainbow
        .getCharacteristic(Characteristic.On)
        .onGet(() => {
          this.platform.assertReachable();
          return this.cycleOn;
        })
        .onSet(async (value) => {
          // Scroll on; Scroll off drops back to the last solid color.
          await this.platform.control({ chromoColor: (value as boolean) ? 'Scroll' : this.lastSolid });
        });
    } else {
      const existing = accessory.getServiceById(Service.Switch, 'rainbow');
      if (existing) {
        accessory.removeService(existing);
      }
    }
  }

  private queueColor(patch: { hue?: number; sat?: number }): void {
    Object.assign(this.pending, patch);
    clearTimeout(this.flushTimer);
    this.flushTimer = setTimeout(() => void this.flushColor(), 150);
  }

  private async flushColor(): Promise<void> {
    const p = this.pending;
    this.pending = {};
    const solid = nearestSolid(p.hue ?? this.hue, p.sat ?? this.sat);

    // Picking a color turns the light to that solid and exits Scroll — it's one enum,
    // so sending the color name is the whole command.
    const body: ControlBody = { chromoColor: solid.value };
    try {
      await this.platform.control(body);
    } catch {
      return; // logged by the platform; poll will restore truth
    }
    // snap the Home app swatch to the actual solid the sauna can produce
    const { Characteristic } = this.platform;
    this.bulb
      .updateCharacteristic(Characteristic.Hue, solid.hue)
      .updateCharacteristic(Characteristic.Saturation, solid.sat);
  }

  applyState(state: SaunadState): void {
    const { Characteristic } = this.platform;
    const color = state.chromoColor;
    this.on = color !== null && color !== 'Off';
    this.cycleOn = color === 'Scroll';

    // While Scroll runs (or the light is off), hold the last solid's swatch rather than
    // chasing the animation; remember any real solid for the On/Scroll-off restore.
    const solid = solidFor(color);
    if (color && color !== 'Off' && color !== 'Scroll') {
      this.lastSolid = color;
    }
    this.hue = solid.hue;
    this.sat = solid.sat;

    this.bulb
      .updateCharacteristic(Characteristic.On, this.on)
      .updateCharacteristic(Characteristic.Hue, this.hue)
      .updateCharacteristic(Characteristic.Saturation, this.sat);
    this.rainbow?.updateCharacteristic(Characteristic.On, this.cycleOn);
  }
}
