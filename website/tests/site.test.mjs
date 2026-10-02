import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
const root = new URL("../", import.meta.url);
const html = readFileSync(new URL("index.html", root), "utf8");
const css = readFileSync(new URL("styles.css", root), "utf8");
test("one main heading, no duplicate IDs, and working fragment targets", () => {
  assert.equal([...html.matchAll(/<h1\b/g)].length, 1);
  const ids = [...html.matchAll(/\bid="([^"]+)"/g)].map((match) => match[1]);
  assert.equal(new Set(ids).size, ids.length);
  for (const [, id] of html.matchAll(/href="#([^"]+)"/g))
    assert.ok(ids.includes(id), `Missing #${id}`);
});
test("local assets exist and external links point to the public project", () => {
  for (const [, path] of html.matchAll(/(?:src|href)="(\/[^"#]+)"/g))
    assert.ok(existsSync(fileURLToPath(new URL(path.slice(1), root))), path);
  for (const [, href] of html.matchAll(/href="(https:[^"]+)"/g))
    assert.ok(href.startsWith("https://github.com/0x1p0") || href === "https://sway-application.vercel.app/", href);
});
test("native controls, explicit demo labels, and reduced-motion support remain", () => {
  assert.equal([...html.matchAll(/type="range"/g)].length, 2);
  assert.equal([...html.matchAll(/<details>/g)].length, 10);
  assert.match(html, /Your Mac’s settings won’t change/);
  assert.match(html, /not notarized by Apple/);
  assert.match(html, /Made with care by/);
  assert.match(css, /prefers-reduced-motion:\s*reduce/);
});
