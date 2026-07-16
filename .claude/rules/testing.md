# Testing and linting

Run the shell linter before every commit:

```
./ci/lint.sh
```

The linter must pass before any commit is made -- do not commit if it reports
findings; fix them first. This applies to every change that touches a shell
script and, as a standing rule, to every commit.
