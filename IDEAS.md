# Ideas / someday backlog

A running list of things to bend the app toward. No commitment, no priority order —
just a place to park the "wouldn't it be nice if…" so it's here when the itch strikes.

The workflow that works: **notice an annoyance mid-session → describe it → see it running
on the real hardware.** Most of these are small because the whole stack is ours (the
SwiftUI app + `saunad` on the G4), so there's no vendor saying no.

How to use this: add a line whenever something occurs to you. Check one off (`[x]`) when
it ships. Keep entries short — a sentence of *what* and *why*, not a spec.

---

## Visibility (show me what's happening)

- [ ] **Live temp-climb graph** — plot cabin temp over the session so you can see the
      heat curve and how close to 160° you are. (saunad already has the data; the log
      browser proved the HTTP→app pattern.)
- [ ] **"Time to temp" estimate** — on the control screen, show ETA to target using the
      learned heat rate (we already track `heatRatePerMin`). "~38 min to 160°."
- [ ] **Session history / stats** — past sessions: duration at temp, peak temp, how long
      the climb took. A simple list to start.
- [ ] **"Why did it shut off?" explainer** — surface the reason a session ended (timer
      reached temp + ran out, deadman, manual, panel) so a surprise shutoff is never a
      mystery.

## Automation (do it without me)

- [ ] **Learned routine** — notice you sauna most Tue/Thu evenings and offer to schedule
      it, instead of you setting each one.
- [ ] **Weather-aware preheat** — lead time already adapts to cabin temp; could also lean
      on outside/ambient cold for the cold-start estimate.
- [ ] **Smarter ready-by** — tighten the preheat estimate as more real climbs are observed.

## Quality of life

- [ ] **"At temp" text notification** — alert the phone the moment the cabin reaches
      target, so you know when to walk out — must reach you with the app closed. **Decided:
      real SMS via Twilio** (there's already a Twilio account from another project). saunad
      already knows the at-temp moment (`_at_temp`); it just needs to fire one SMS per climb
      (debounced so a flaky reading can't spam). Twilio creds (account SID, auth token,
      from-number, your to-number) go in the gitignored `options.json` — never in the repo.
- [ ] **Offer to launch the VPN when it can't reach saunad** — when the app fails to
      connect (you're off the home Wi-Fi), show a "Connect via Tailscale" button that opens
      the VPN, then auto-retry. saunad is already reachable over Tailscale; this just removes
      the manual "oh right, turn on the VPN" step.
- [ ] **Home Screen widget** — current temp / heating state at a glance.
- [ ] **Lock Screen control** — start/stop or set a timer without opening the app.
      (Live Activity already works; a Control Center / Lock Screen control is the next step.)
- [ ] **Siri / Shortcuts** — "Hey Siri, start the sauna" / "set a 30-minute session."

## Plumbing / cleanup

- [ ] **Remove the leftover Sonos "Sauna Speaker" card** — audio is local Bluetooth on the
      FD-5 pad, not on Tuya; that card is fork leftover.
- [ ] **Enable Push on the App ID** (optional) — unlocks remote Live Activity temp updates
      and the at-temp notification above.

---

*Shipped recently (so the momentum is visible):*

- [x] Heat timer counts from reaching target, not from heating start.
- [x] Preheat no longer cuts out with a pending timer (FD-5 needs its own timer > 0 to heat).
- [x] "⏳ starts at 160°" pending indicator on the timer pill.
- [x] Schedules actually fire (saunad runs the loop; the app syncs them up).
- [x] In-app saunad log browser (Settings → "saunad logs").
