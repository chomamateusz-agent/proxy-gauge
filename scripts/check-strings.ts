import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";

type StringUnit = { state?: string; value?: string };
type Localization = { stringUnit?: StringUnit; variations?: Record<string, Record<string, { stringUnit?: StringUnit }>> };
type Entry = { extractionState?: string; shouldTranslate?: boolean; localizations?: Record<string, Localization> };
type Catalog = { sourceLanguage?: string; strings?: Record<string, Entry> };
type StringsData = { source?: string; tables?: Record<string, { key?: string; location?: { startingLine?: number } }[]> };
export type ExtractedString = { key: string; source: string; line?: number };

const root = resolve(import.meta.dir, "..");
const catalogs = ["Apple/SharedUI/Localizable.xcstrings", "Apple/iOS/InfoPlist.xcstrings"];
const uiTable = "Localizable";
const appTargets = ["PhoneApp", "PhoneWidgets", "MacApp"];
const languages = ["en", "pl"];

function unitValues(localization: Localization | undefined): string[] {
  if (!localization) return [];
  if (localization.stringUnit?.value?.trim()) return [localization.stringUnit.value];
  return Object.values(localization.variations ?? {}).flatMap((forms) =>
    Object.values(forms).flatMap((form) => (form.stringUnit?.value?.trim() ? [form.stringUnit.value] : [])),
  );
}

function placeholders(text: string): string[] {
  return (text.match(/%(\d+\$)?(lld|ld|d|@|f|\.\d+f|lf)/g) ?? []).map((token) => token.replace(/^%\d+\$/, "%")).sort();
}

export function catalogErrors(catalog: Catalog): string[] {
  const failures: string[] = [];
  if (catalog.sourceLanguage !== "en") failures.push("source language must be en");
  const entries = Object.entries(catalog.strings ?? {});
  if (entries.length === 0) failures.push("catalog is empty");
  for (const [key, entry] of entries) {
    if (entry.extractionState === "stale") failures.push(`${key}: stale, no longer used in code`);
    if (entry.shouldTranslate === false) continue;
    const expected = placeholders(key);
    for (const language of languages) {
      const values = unitValues(entry.localizations?.[language]);
      if (values.length === 0) {
        failures.push(`${key}: missing ${language}`);
        continue;
      }
      for (const value of values) {
        if (placeholders(value).join(",") !== expected.join(",")) failures.push(`${key}: ${language} placeholders differ`);
      }
    }
  }
  return failures;
}

export function stringsdataFiles(derived: string, targets: string[] = appTargets): string[] {
  const found: string[] = [];
  const walk = (directory: string) => {
    for (const name of readdirSync(directory)) {
      const path = join(directory, name);
      if (statSync(path).isDirectory()) walk(path);
      else if (name.endsWith(".stringsdata") && targets.some((target) => path.includes(`/${target}.build/`))) found.push(path);
    }
  };
  if (existsSync(derived)) walk(derived);
  return found.sort();
}

export function extractedStrings(documents: StringsData[], sourceExists: (path: string) => boolean = existsSync): ExtractedString[] {
  const unique = new Map<string, ExtractedString>();
  for (const document of documents) {
    if (!document.source || !sourceExists(document.source)) continue;
    for (const entry of document.tables?.[uiTable] ?? []) {
      if (entry.key === undefined) continue;
      unique.set(`${document.source}\u0000${entry.key}`, { key: entry.key, source: document.source, line: entry.location?.startingLine });
    }
  }
  return [...unique.values()];
}

export function missingFromCatalog(extracted: ExtractedString[], catalog: Catalog): ExtractedString[] {
  const known = new Set(Object.keys(catalog.strings ?? {}));
  return extracted.filter((item) => !known.has(item.key));
}

async function sync(derived: string) {
  const files = stringsdataFiles(resolve(root, derived));
  if (files.length === 0) throw new Error(`No .stringsdata under ${derived}; run make build-ios and make build-mac first.`);
  const process = Bun.spawnSync(["xcrun", "xcstringstool", "sync", join(root, catalogs[0]), ...files.flatMap((file) => ["--stringsdata", file])]);
  if (process.exitCode !== 0) throw new Error(process.stderr.toString());
  console.log(`Synced ${catalogs[0]} from ${files.length} stringsdata files`);
}

function checkExtracted(derived: string, targets: string[], catalog: Catalog): boolean {
  const files = stringsdataFiles(resolve(root, derived), targets);
  if (files.length === 0) {
    console.error(`No .stringsdata for ${targets.join(", ")} under ${derived}; the build did not extract any strings.`);
    return false;
  }
  const extracted = extractedStrings(files.map((file) => JSON.parse(readFileSync(file, "utf8")) as StringsData));
  const missing = missingFromCatalog(extracted, catalog);
  if (missing.length) {
    const lines = missing.map((item) => `${item.source.replace(`${root}/`, "")}:${item.line ?? "?"}: "${item.key}"`);
    console.error(`Strings the compiler extracted for ${targets.join(", ")} are missing from ${catalogs[0]} (run make strings, then translate):\n  ${lines.join("\n  ")}`);
    return false;
  }
  console.log(`Extracted strings OK: ${new Set(extracted.map((item) => item.key)).size} keys from ${targets.join(", ")} are in the catalog`);
  return true;
}

if (import.meta.main) {
  const argument = (name: string) => {
    const index = process.argv.indexOf(name);
    return index === -1 ? undefined : process.argv[index + 1];
  };
  const syncFrom = argument("--sync");
  if (syncFrom !== undefined) await sync(syncFrom);
  let failed = false;
  for (const relative of catalogs) {
    const catalog: Catalog = await Bun.file(join(root, relative)).json();
    const failures = catalogErrors(catalog);
    if (failures.length) {
      console.error(`${relative}:\n  ${failures.join("\n  ")}`);
      failed = true;
    } else {
      console.log(`String catalog OK: ${relative} ${Object.keys(catalog.strings ?? {}).length} keys, en + pl`);
    }
  }
  const extractedFrom = argument("--extracted");
  if (extractedFrom !== undefined) {
    const targets = (argument("--targets") ?? appTargets.join(",")).split(",");
    const uiCatalog: Catalog = await Bun.file(join(root, catalogs[0])).json();
    if (!checkExtracted(extractedFrom, targets, uiCatalog)) failed = true;
  }
  if (failed) process.exit(1);
}
