# RunKit — Differentiation & Enhancement Research

> Companion to `REQUIREMENTS.md`. Strategy notes, not committed scope. The point
> of this doc: privacy-first is the *floor*, not the pitch. "Private Strava" is a
> subtraction — it tells users what RunKit *doesn't* do. This lists the things
> RunKit can do that the incumbents **structurally cannot**, and grades each on
> effort vs. payoff.

---

## 1. Competitive read — where each leader is weak

| Product | What it is | The weakness RunKit exploits |
|---|---|---|
| **Apple Health / Fitness** | The default data store + Move/Exercise/Stand rings. | A *warehouse*, not a coach. Superb at storing HealthKit data, weak at **planning, structured sessions, and personality**. Rings are generic, not run-goal-specific. No training-plan generator, no route/session scheduling, no coaching voice. |
| **Strava** | Social-first, subscription. Segments, leaderboards, route discovery, heatmaps. | **Privacy** (public feeds by default; the 2018 heatmap exposed military bases). **Account required**, everything uploads to servers. Aggressive paywall on analysis + planning. Heavy. Sells the social graph as the product. |
| **Nike Run Club / adidas Running** | Free guided runs + plans, brand ecosystem. | **Account required**, data harvested for marketing; ad/upsell heavy; guided content is server-gated and can vanish. No on-device ownership. |
| **Gentler Streak / Athlytic** | HealthKit-based recovery/readiness, privacy-friendlier. | **Subscription** for readiness/HRV. Single-domain — they can't see your *strength* training. No structured run builder or route recording. |
| **Pedometer++ / StepsApp** | Privacy-first step counters. | Passive only — **no sessions, no coaching, no planning, no route.** RunKit already passes them the moment a Run starts. |

**Takeaway:** every incumbent is either (a) a server-bound social/subscription product, or (b) a single-domain tracker. RunKit's opening is the **intersection nobody occupies**: an on-device, no-account, *coached & planned* cardio app that can see the rest of your training.

---

## 2. The three moats competitors can't copy

These aren't features — they're structural advantages that follow from RunKit's architecture and the suite. Prioritize building *these*, because Strava/Apple/Nike literally can't follow.

### Moat 1 — The suite sees your whole body of training (HealthKit fusion)
RunKit + LiftKit + FuelKit all read/write one HealthKit bus. **No single-app competitor can do this.** Concrete features it unlocks:
- **Recovery-aware scheduling.** The planned calendar reads LiftKit workouts + resting HR / HRV / sleep from HealthKit and *adjusts the plan*: "You squatted heavy yesterday — today's tempo run is downgraded to an easy shakeout." Athlytic charges a subscription for readiness and still can't see your lifts. RunKit does it free, cross-domain.
- **One active-energy budget** across strength + cardio + (later) food. FuelKit reads the combined burn; RunKit's targets reflect that you also lifted.
- **Cross-training credit.** A leg day counts toward weekly load so the plan doesn't over-prescribe running.

*This is the single most defensible thing RunKit can build. It's the reason the suite exists.*

### Moat 2 — Coaching with a personality (extends the voice work already shipped)
The deadpan/sarcastic coach voice is **already a brand no one else has** — Nike is earnest, Strava is a spreadsheet, Apple is neutral. This is memorable and word-of-mouth-shareable. Extend it, cheaply, since it's all on-device TTS clips:
- **Selectable coach personalities:** Deadpan (current), Hype, Zen, Drill Sergeant. Same cue-token system, different clip packs. Low effort, high delight, strong App Store screenshot/marketing hook.
- Personality persists across modes (intervals, pace, free) — already wired through `VoiceCue`.

### Moat 3 — Real training structure, free and offline (no account, no paywall)
The interval/pace builder already exists. Turn it into a **planning product**:
- **On-device training-plan generator.** Pick a goal (first 5K, sub-25 5K, 10K, half) and a race date → generate a week-by-week plan into the calendar, entirely on-device. Strava paywalls this; Nike requires login; nobody does it privately. This is what makes the *planned calendar* a killer feature instead of a scheduler.
- **Free structured-workout library** shipped as data: C25K, tempo, fartlek, hill repeats, Yasso 800s. No download, no account. Each is just an interval/pace session the engine already runs.

---

## 3. Enhancement backlog — graded

**Legend:** Effort ▁ low ▃ medium ▇ high · Payoff ★–★★★

### Near-term, cheap wins
| Idea | Effort | Payoff | Notes |
|---|---|---|---|
| **Coach personality packs** | ▃ | ★★★ | Reuses voice pipeline; marketing gold. |
| **App Intents / Siri / Shortcuts** | ▃ | ★★ | "Hey Siri, start a RunKit run"; Home-screen/Action-button start; Automations ("when I arrive at the park, start a walk"). On-device power-user hook Strava lacks. |
| **Free structured-workout library** | ▃ | ★★★ | Data-only; engine already runs it. Undercuts NRC/Strava paywalls. |
| **Honest streaks** | ▁ | ★★ | Streaks that respect rest days (Gentler Streak's pitch) — no guilt/nag dark patterns. On-brand. |
| **Privacy zones on route maps** | ▃ | ★★ | Auto-blur start/end near saved "home" for any screenshot the user chooses to share. Strava added this *after* the scandal, server-side; RunKit does it natively. |
| **True data export** | ▁ | ★ | Full GPX/CSV already roadmapped — frame it loudly as "your data, actually portable." |

### Bigger bets (ride on the calendar + Watch you're already planning)
| Idea | Effort | Payoff | Notes |
|---|---|---|---|
| **Training-plan generator → calendar** | ▇ | ★★★ | Makes the planned calendar a *reason to switch*, not a nicety. |
| **Recovery-aware scheduling (HealthKit fusion)** | ▇ | ★★★ | Moat 1. Reads LiftKit + HRV/sleep to tune the plan. Nobody can copy. |
| **Readiness score (HRV + resting HR)** | ▃ | ★★ | Reads HealthKit; give free what Athlytic/Gentler Streak subscribe-gate. |
| **Watch app (on-wrist GPS + HR, phone-free)** | ▇ | ★★★ | Table stakes for cardio; already v2. Live Activity is done and already beats Strava's. |
| **StandBy / lock-screen widgets** | ▃ | ★★ | Already v1.1 roadmap. |

### Positioning (not code)
- **Anti-subscription.** In a subscription-fatigued market, a one-time purchase or generous free tier is itself a differentiator. Everyone else rents. Decide the model deliberately (mirror LiftKit's free/Plus split).
- **"Data Not Collected" as hero copy**, not fine print — the App Store label is a marketing asset against Strava's data reputation.

---

## 4. Guardrails — do NOT build these to compete
Staying disciplined *is* the product. Explicitly out, even though competitors have them:
- Social / feeds / leaderboards / segments / clubs / challenges (hard line — §3 of REQUIREMENTS).
- Accounts, server sync to anything but the user's own iCloud.
- Curated "explore routes/trails" content, in-app community, ads, third-party SDKs.
- Gamified guilt (nagging notifications, streak-shaming).

The moment RunKit adds a feed, it becomes a worse Strava. The whole thesis is the opposite.

---

## 5. One-line pitch candidates
- "A running coach that plans your week, keeps its mouth shut, and never phones home."
- "Structured training and a coach with an attitude — no account, no cloud, no nagging."
- "The only run app that also knows you lifted yesterday."  ← leans on the suite moat
