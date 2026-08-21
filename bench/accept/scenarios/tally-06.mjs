// bench/accept/scenarios/tally-06.mjs -- oracle-authored scenario for
// bench/issues/06-tally-dark-mode-toggle.md. Executes ONLY inside the
// forked scenario-runner child (PR #363 review finding 1). Only the
// toggleTheme() calls need isolation -- the style.css/index.html checks
// in bench/accept/tally-06.test.mjs execute no target code (plain fs
// reads) and stay in that process.
export default async function run({ importTarget }) {
  const theme = await importTarget('src/theme.js');

  const toggleThemeFnType = typeof theme.toggleTheme;
  if (toggleThemeFnType !== 'function') {
    return { toggleThemeFnType };
  }

  return {
    toggleThemeFnType,
    lightToDark: theme.toggleTheme('light'),
    darkToLight: theme.toggleTheme('dark'),
    undefinedToDark: theme.toggleTheme(undefined),
  };
}
