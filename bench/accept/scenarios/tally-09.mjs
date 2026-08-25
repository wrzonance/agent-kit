// bench/accept/scenarios/tally-09.mjs -- oracle-authored scenario for
// bench/issues/09-tally-import-json.md. Executes ONLY inside the forked
// scenario-runner child (PR #363 review finding 1). Returns the parsed
// `ok` result value itself rather than a precomputed JSON.stringify()
// equality boolean (PR #363 review finding 4) -- key insertion order
// changes JSON.stringify()'s text without changing the value it
// represents, so a compliant target could otherwise fail this scenario
// for free.
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
    ok,
    badJsonThrew,
    badJsonOk: badJson?.ok,
    badJsonErrorType: typeof badJson?.error,
    badJsonErrorNonEmpty: typeof badJson?.error === 'string' && badJson.error.length > 0,
    badShapeThrew,
    badShapeOk: badShape?.ok,
  };
}
