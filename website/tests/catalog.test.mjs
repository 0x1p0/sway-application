import test from "node:test";
import assert from "node:assert/strict";
import { matchesAction, normalizeSearch } from "../catalog.mjs";

test("search ignores case, accents, and surrounding whitespace", () => {
  assert.equal(normalizeSearch("  APP EXPOSÉ  "), "app expose");
  assert.ok(matchesAction("App Exposé", "expose", "windows"));
});
test("all actions are discoverable with an empty query", () => {
  assert.ok(matchesAction("Keyboard backlight", "   ", "display"));
});
test("search matches every word, not just the first", () => {
  assert.ok(matchesAction("Microphone level default input gain", "GAIN microphone", "audio"));
  assert.equal(matchesAction("Microphone level", "microphone keyboard", "audio"), false);
});
test("search and category filters intersect", () => {
  assert.ok(matchesAction("Speaker mute", "mute", "audio", "audio"));
  assert.equal(matchesAction("Speaker mute", "mute", "audio", "windows"), false);
  assert.equal(matchesAction("Speaker mute", "unknown", "audio", "audio"), false);
});
test("search treats metacharacters as literal text", () => {
  assert.equal(matchesAction("Speaker mute", ".*", "audio"), false);
  assert.ok(matchesAction("Command-[", "[", "navigation"));
});
