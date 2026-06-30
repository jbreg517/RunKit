// Emits manifest.json: { "<clipID>": "<text to speak>" } for the natural voice
// cue pack (option B). Mirrors the vocabulary in RunKit/Services/VoiceCue.swift —
// keep the two in sync. Run: `node build-manifest.js`
const fs = require("fs");

const m = {};

// Numbers 0–99 (rendered in a neutral, non-final tone during generation).
for (let i = 0; i <= 99; i++) m[`n_${i}`] = String(i);

// Units / connectives.
Object.assign(m, {
  point: "point",
  minute: "minute", minutes: "minutes",
  second: "second", seconds: "seconds",
  per_km: "per kilometer", per_mi: "per mile",
  km_mark: "Kilometer", mi_mark: "Mile",
  km_singular: "kilometer", km_plural: "kilometers",
  mi_singular: "mile", mi_plural: "miles",
  kmh: "kilometers per hour", mph: "miles per hour",
  time: "Time", avg_pace: "Average pace", avg_speed: "Average speed",
  in: "in", reached: "reached", complete: "complete", go: "Go",
  walk: "Walk", run: "Run", ride: "Ride", unavailable: "unavailable",
});

// Whole motivation phrases (must match Motivation in VoiceCue.swift).
const goalLines = [
  "Goal smashed! Outstanding.",
  "You did it — that's a win.",
  "Target hit. Unstoppable today.",
  "Boom. Goal complete.",
  "That's the one. Brilliant work.",
  "Winged it all the way. Superb.",
];
const finishLines = [
  "Strong finish — be proud of that one.",
  "Nice work out there. Every step counted.",
  "That's how it's done. Recover well.",
  "Great effort. Mercury would be proud.",
  "You showed up and crushed it.",
  "Another one in the bank. Keep building.",
  "Legs of the gods today. Well run.",
];
goalLines.forEach((t, i) => (m[`goal_${i}`] = t));
finishLines.forEach((t, i) => (m[`finish_${i}`] = t));
m.sample = "Kilometer three. Nice work — you're flying.";

fs.writeFileSync("manifest.json", JSON.stringify(m, null, 2) + "\n");
console.log(`wrote manifest.json with ${Object.keys(m).length} clips`);
