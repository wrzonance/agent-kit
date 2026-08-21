// bench/accept/scenarios/tally-07.mjs -- oracle-authored scenario for
// bench/issues/07-tally-keyboard-shortcuts.md. Executes ONLY inside the
// forked scenario-runner child (PR #363 review finding 1).
export default async function run({ importTarget }) {
  const keyboard = await importTarget('src/keyboard.js');

  const matchShortcutFnType = typeof keyboard.matchShortcut;
  if (matchShortcutFnType !== 'function') {
    return { matchShortcutFnType };
  }

  return {
    matchShortcutFnType,
    plus: keyboard.matchShortcut({ key: '+' }),
    minus: keyboard.matchShortcut({ key: '-' }),
    del: keyboard.matchShortcut({ key: 'Delete' }),
    other: keyboard.matchShortcut({ key: 'a' }),
  };
}
