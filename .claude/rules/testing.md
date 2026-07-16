# Testing and linting

Run the full CI suite before every commit:

```
./ci/run.sh
```

It builds the CI container on first use, then runs shellcheck, vint (Vimscript
lint), the headless functional tests on vim 8.2 and neovim 0.12.4, the shell
assertions, and the golden screen-dump tests. Everything must pass before any
commit is made -- do not commit if it reports findings; fix them first. This
applies to every change and, as a standing rule, to every commit.

If a change intentionally alters the rendered view, regenerate the committed
screen-dump goldens and review the diff before committing:

```
NEODIFF_UPDATE=1 ./ci/run.sh
```
