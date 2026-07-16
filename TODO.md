## Add tests

Currently verified only by manual headless runs (`vim -Nu NONE -es -S probe.vim`)
and `zsh -n`. We want a real, repeatable suite.

- Consider [`vader.vim`](https://github.com/junegunn/vader.vim) for the Vimscript
  side, or a hand-rolled headless runner that sources `autoload/neodiff.vim`,
  calls `neodiff#Setup(...)` with fixtures, and asserts on buffer contents / tab
  state.
- Run with `-N` (nocompatible); do **not** load the full `~/.vimrc` (coc etc.
  are `-es`-hostile). Source only the plugin.
- Cases to cover: tree build + sort order; auto-expand vs collapse threshold;
  directory toggle; select-to-tab; reopen-after-close; close-tab-on-`:q` (drive
  the `timer` with `:sleep`); stat-column alignment; title bar prev/next +
  wraparound + pluralization; `RefreshStats` against a temp git repo.
- Shell side: a small bats-style or plain-sh harness asserting on the generated
  `entries`/`refresh`/`diff_setup` strings for each arg pattern (`""`,
  `--staged`, `<rev>`, `<rev1> <rev2>`), and the submodule/dir filtering.

## More helpful hotkeys

- shortcut to hide the "global" sidebar

## Search for symbols used in current gdifftree view
Use fzf if available, fallback to ctags, fallback to (what other options do we have?)

## De-scope the blame view for now (disable pressing enter in the fugitive view opening the blame)

## preserve selected pane across tabs

If I am currently on the "sidebar", when going to the next tab, I should still be on the sidebar

## Meta "change list" for for git diff range commands
For example, when running `gdiff HEAD~4^..HEAD~` create a pinned 'Diff Commits' entry (in the similar place as 'Commit
Description' which shows which commits are being shown. Bonus points if each commit's message was a separate entry in
the pinned tree.

## Bug: gdiff <pathspec> doesn't render diffs correctly

## Add hook to Plugin install which sources the bash commands to bashrc/zshrc/etc.
