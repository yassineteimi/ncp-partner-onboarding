#!/usr/bin/env node
// Generate the narration with a HeyGen voice through the HeyGen API key (billed to the
// HeyGen API balance), one mp3 plus word timings per scene.
//
//   VOICE_ID=<voice id> node scripts/make-voice-api.mjs            all scenes
//   VOICE_ID=<voice id> node scripts/make-voice-api.mjs s01 s05    only these
//
// The key comes from $HEYGEN_API_KEY, else ~/.heygen_api_key. Reads voice/lines.tsv
// (scene id, tab, text) and writes assets/voice/<id>.mp3 and assets/voice/<id>.words.json.
// The engine is named explicitly: /v3/voices/speech refuses a voice whose saved engine
// isn't starfish, even when starfish is in its available_engines.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const voiceId = process.env.VOICE_ID;
if (!voiceId) {
  console.error("Set VOICE_ID (GET https://api.heygen.com/v3/voices?type=private lists your voices).");
  process.exit(1);
}
const key = (process.env.HEYGEN_API_KEY || readFileSync(join(homedir(), ".heygen_api_key"), "utf8")).trim();
const engine = process.env.ENGINE || "starfish";
const speed = Number(process.env.SPEED || "1.0");
const wanted = new Set(process.argv.slice(2));

const lines = readFileSync(join(root, "voice/lines.tsv"), "utf8")
  .split("\n")
  .filter(Boolean)
  .map((l) => l.split("\t"));

mkdirSync(join(root, "assets/voice"), { recursive: true });
for (const [id, text] of lines) {
  if (wanted.size && !wanted.has(id)) continue;
  const r = await fetch("https://api.heygen.com/v3/voices/speech", {
    method: "POST",
    headers: { "x-api-key": key, "content-type": "application/json", accept: "application/json" },
    body: JSON.stringify({ text, voice_id: voiceId, speed, engine }),
  });
  const body = await r.json();
  if (!r.ok || !body.data?.audio_url) {
    console.error(`${id}: HTTP ${r.status} ${JSON.stringify(body).slice(0, 300)}`);
    process.exit(1);
  }
  const audio = await fetch(body.data.audio_url);
  writeFileSync(join(root, `assets/voice/${id}.mp3`), Buffer.from(await audio.arrayBuffer()));
  const words = (body.data.word_timestamps || []).filter((w) => !/^<.*>$/.test(w.word));
  writeFileSync(join(root, `assets/voice/${id}.words.json`), JSON.stringify({ text, duration: body.data.duration, words }, null, 1) + "\n");
  console.log(`${id}: ${body.data.duration.toFixed(2)} s, ${words.length} words`);
}
