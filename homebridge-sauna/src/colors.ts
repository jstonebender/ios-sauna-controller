/** The Finnmark FD-5's chromotherapy palette (Tuya DP111) in HomeKit hue/sat terms.
 *  Mirrors app/Shared/ChromaPalette.swift. The device light is a plain enum whose
 *  value IS the color name ("Red", "Blue", …) — unlike the Eclipse 2's "modeN" codes.
 *  "White" is the low-saturation center; "Scroll" (the color cycle) and "Off" are
 *  handled by the lights accessory, not here. */

export interface Solid {
  /** The literal FD-5 chromoColor enum value sent to saunad. */
  value: string;
  name: string;
  hue: number; // 0-360
  sat: number; // 0-100
}

export const WHITE: Solid = { value: 'White', name: 'White', hue: 0, sat: 0 };

export const CHROMATIC: Solid[] = [
  { value: 'Red', name: 'Red', hue: 0, sat: 100 },
  { value: 'Orange', name: 'Orange', hue: 30, sat: 100 },
  { value: 'Yellow', name: 'Yellow', hue: 55, sat: 100 },
  { value: 'Green', name: 'Green', hue: 120, sat: 100 },
  { value: 'Cyan', name: 'Cyan', hue: 180, sat: 100 },
  { value: 'Blue', name: 'Blue', hue: 240, sat: 100 },
  { value: 'Purple', name: 'Purple', hue: 270, sat: 100 },
  { value: 'Magenta', name: 'Magenta', hue: 300, sat: 100 },
];

const hueDistance = (a: number, b: number): number => {
  const d = Math.abs(a - b) % 360;
  return d > 180 ? 360 - d : d;
};

/** Snap a HomeKit color pick to the nearest real solid. Low saturation is the wheel's
 *  whitish center — treat it as White regardless of hue. The chromatic solids are
 *  >= 30° apart in hue, so hue-only distance stays unambiguous. */
export function nearestSolid(hue: number, sat: number): Solid {
  if (sat < 25) {
    return WHITE;
  }
  let best = CHROMATIC[0];
  for (const s of CHROMATIC) {
    if (hueDistance(hue, s.hue) < hueDistance(hue, best.hue)) {
      best = s;
    }
  }
  return best;
}

/** Device -> HomeKit swatch. "White", "Scroll", "Off", null and anything unknown all
 *  render as the white center (while scrolling, the swatch just holds white). */
export function solidFor(value: string | null | undefined): Solid {
  return CHROMATIC.find((s) => s.value === value) ?? WHITE;
}
