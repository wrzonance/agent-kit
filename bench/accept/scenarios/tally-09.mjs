// bench/accept/scenarios/tally-09.mjs -- oracle-authored scenario for
// bench/issues/09-tally-import-json.md. Executes ONLY inside the forked
// scenario-runner child (PR #363 review finding 1).
export default async function run({ importTarget }) {
  const importer = await importTarget('src/importer.js');

  const parseImportFnType = typeof importer.parseImport;
  if (parseImportFnType !== 'function') {
    return { parseImportFnType };
  }

  const ok = importer.parseImport('{"items":[],"nextId":1}');

  let badJsonThrew = false;
  let badJson;
  try {
    badJson = importer.parseImport('not json');
  } catch {
    badJsonThrew = true;
  }

  let badShapeThrew = false;
  let badShape;
  try {
    badShape = importer.parseImport('{"nextId":1}');
  } catch {
    badShapeThrew = true;
  }

  return {
    parseImportFnType,
    okResultMatches: JSON.stringify(ok) === JSON.stringify({ ok: true, state: { items: [], nextId: 1 } }),
    badJsonThrew,
    badJsonOk: badJson?.ok,
    badJsonErrorType: typeof badJson?.error,
    badJsonErrorNonEmpty: typeof badJson?.error === 'string' && badJson.error.length > 0,
    badShapeThrew,
    badShapeOk: badShape?.ok,
  };
}
