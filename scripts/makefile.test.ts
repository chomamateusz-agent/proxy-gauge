import { expect, test } from "bun:test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const repo = join(import.meta.dir, "..");
const stubbedTools = ["swift", "bun", "xcodebuild", "bash"];
const exportedByAnOuterMake = ["MAKEFLAGS", "MFLAGS", "MAKELEVEL", "MAKEOVERRIDES", "CONFIRM", "ASC_ENV", "PLATFORM"];

function runReleaseGate(extraArgs: string[], parentEnv: Record<string, string> = {}) {
  const sandbox = mkdtempSync(join(tmpdir(), "release-gate-"));
  try {
    const log = join(sandbox, "calls.log");
    writeFileSync(log, "");
    const ascEnv = join(sandbox, "asc.env");
    writeFileSync(ascEnv, "");
    for (const tool of stubbedTools) {
      const stub = join(sandbox, tool);
      writeFileSync(stub, `#!/bin/sh\necho "start ${tool} $*" >> "${log}"\nsleep 0.2\necho "end ${tool} $*" >> "${log}"\n`);
      chmodSync(stub, 0o755);
    }
    const env: Record<string, string | undefined> = { ...process.env, ...parentEnv, PATH: `${sandbox}:${process.env.PATH}` };
    for (const inherited of exportedByAnOuterMake) delete env[inherited];
    const result = Bun.spawnSync(["make", "-j8", "--no-print-directory", "testflight", `ASC_ENV=${ascEnv}`, ...extraArgs], { cwd: repo, env, stdout: "pipe", stderr: "pipe" });
    const calls = readFileSync(log, "utf8").split("\n").filter(Boolean);
    return { exitCode: result.exitCode, calls };
  } finally {
    rmSync(sandbox, { recursive: true, force: true });
  }
}

test("release gate refuses before running anything when the confirmation is missing, even under make -j", () => {
  const { exitCode, calls } = runReleaseGate([]);
  expect(exitCode).toBe(2);
  expect(calls).toEqual([]);
});

test("release gate refusal test ignores a confirmation exported by the outer make testflight", () => {
  const { exitCode, calls } = runReleaseGate([], { CONFIRM: "example.bundle", ASC_ENV: "/nonexistent/asc.env", PLATFORM: "ios" });
  expect(exitCode).toBe(2);
  expect(calls).toEqual([]);
});

test("release gate runs tests and both builds one at a time before uploading, even under make -j", () => {
  const { exitCode, calls } = runReleaseGate(["CONFIRM=example.bundle"]);
  expect(exitCode).toBe(0);
  let running = 0;
  for (const call of calls) {
    running += call.startsWith("start ") ? 1 : -1;
    expect(running).toBeLessThanOrEqual(1);
  }
  const starts = calls.filter((call) => call.startsWith("start "));
  const position = (fragment: string) => starts.findIndex((call) => call.includes(fragment));
  const order = ["swift test", "-scheme PhoneApp", "-scheme MacApp", "appstore-upload.sh"].map(position);
  expect(order.every((index) => index >= 0)).toBe(true);
  expect(order).toEqual([...order].sort((a, b) => a - b));
});
