/** Thin fetch client for the saunad HTTP API (zero dependencies, node >= 18). */

export interface SaunadState {
  power: boolean;
  heater: boolean;
  currentTempF: number | null; // hidden (null) while powered off — the FD-5 reports stale temps
  currentTempC: number | null;
  targetTempF: number | null;
  targetTempC: number | null;
  timerSetMin: number | null;
  timerRemainingMin: number | null;
  chromoColor: string | null; // FD-5 light enum: White, Red, …, Scroll; "Off" while powered off
  unit: string;
  online: boolean;
  heaterInterruptedAt: number | null; // set when the heater went off without an app command (panel tap)
  updatedAt: number;
}

export interface ControlBody {
  power?: boolean;
  heater?: boolean;
  targetTempF?: number; // 86-170
  timerMin?: number; // 0-90
  chromoColor?: string; // White, Red, Orange, Yellow, Green, Cyan, Blue, Purple, Magenta, Scroll, Off
}

export class AuthError extends Error {
  constructor() {
    super('saunad rejected the API key (401)');
  }
}

export class SaunadClient {
  constructor(
    private readonly baseUrl: string,
    private readonly apiKey?: string,
  ) {}

  async getState(): Promise<SaunadState> {
    const res = await fetch(`${this.baseUrl}/state`, { signal: AbortSignal.timeout(4000) });
    if (!res.ok) {
      throw new Error(`GET /state ${res.status}`);
    }
    return (await res.json()) as SaunadState;
  }

  /** POST /control does verified Tuya writes (write → read back → confirm the DP
   *  changed) — generous timeout. */
  async control(body: ControlBody): Promise<SaunadState> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (this.apiKey) {
      headers.Authorization = `Bearer ${this.apiKey}`;
    }
    const res = await fetch(`${this.baseUrl}/control`, {
      method: 'POST',
      headers,
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(30000),
    });
    if (res.status === 401) {
      throw new AuthError();
    }
    if (!res.ok) {
      throw new Error(`POST /control ${res.status}`);
    }
    return (await res.json()) as SaunadState;
  }
}
