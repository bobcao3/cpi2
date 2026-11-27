import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { stage_wrapper } from "../scripts/ghostmux-package.mjs";

test("local packaging loads and stages public wrapper metadata with versioned aliases", { timeout: 10000 }, async () => {
  const usage = spawnSync(process.execPath, [fileURLToPath(new URL("../scripts/package.mjs", import.meta.url))], { encoding: "utf8", timeout: 5000 });
  assert.ifError(usage.error);
  assert.equal(usage.status, 1);
  assert.match(usage.stderr, /Usage: package\.mjs ARTIFACT_DIRECTORY NEW_DESTINATION/);
  const directory = await mkdtemp(join(tmpdir(), "ghostmux-package-"));
  try {
    const manifest = await stage_wrapper(directory);
    const saved = JSON.parse(await readFile(join(directory, "package.json"), "utf8"));
    assert.deepEqual(saved, manifest);
    assert.equal(saved.name, "@bobcao3/cpi-ghostmux");
    const source = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
    assert.equal(saved.version, source.version);
    const expected = {};
    for (const platform of ["linux-x64", "linux-arm64", "darwin-x64", "darwin-arm64", "win32-x64"]) {
      expected[`@cpi/ghostmux-${platform}`] = `npm:@bobcao3/cpi-ghostmux-${platform}@${source.version}`;
    }
    assert.deepEqual(saved.optionalDependencies, expected);
    assert.equal(saved.private, undefined);
    assert.equal(saved.exports["./package"], undefined);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
});
