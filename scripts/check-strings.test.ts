import { expect, test } from "bun:test";
import { catalogErrors, extractedStrings, missingFromCatalog } from "./check-strings";

const translated = (en: string, pl: string) => ({
  localizations: { en: { stringUnit: { state: "translated", value: en } }, pl: { stringUnit: { state: "translated", value: pl } } },
});

test("reports compiler-extracted keys that the catalog lacks", () => {
  const documents = [
    {
      source: "/repo/Apple/Shared/View.swift",
      tables: {
        Localizable: [
          { key: "Refresh", location: { startingLine: 3 } },
          { key: "Updated %@ ago", location: { startingLine: 9 } },
          { key: "Missing raw string", location: { startingLine: 12 } },
        ],
        InfoPlist: [{ key: "CFBundleDisplayName" }],
      },
    },
  ];
  const catalog = { sourceLanguage: "en", strings: { Refresh: translated("Refresh", "Odśwież"), "Updated %@ ago": translated("Updated %@ ago", "Zaktualizowano %@ temu") } };
  const missing = missingFromCatalog(extractedStrings(documents, () => true), catalog);
  expect(missing).toEqual([{ key: "Missing raw string", source: "/repo/Apple/Shared/View.swift", line: 12 }]);
});

test("ignores stringsdata left behind by deleted sources and duplicate architectures", () => {
  const entry = { source: "/repo/Kept.swift", tables: { Localizable: [{ key: "Kept" }] } };
  const documents = [entry, entry, { source: "/repo/Deleted.swift", tables: { Localizable: [{ key: "Gone" }] } }];
  const extracted = extractedStrings(documents, (path) => path === "/repo/Kept.swift");
  expect(extracted.map((item) => item.key)).toEqual(["Kept"]);
});

test("catalog entries need English and Polish with matching placeholders", () => {
  const catalog = {
    sourceLanguage: "en",
    strings: {
      Good: translated("Good", "Dobrze"),
      "Count %lld": translated("Count %lld", "Liczba"),
      Untranslated: { localizations: { en: { stringUnit: { value: "Untranslated" } } } },
    },
  };
  expect(catalogErrors(catalog)).toEqual(["Count %lld: pl placeholders differ", "Untranslated: missing pl"]);
});
