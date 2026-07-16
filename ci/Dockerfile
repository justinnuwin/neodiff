# Minimal image for linting neodiff's shell scripts with shellcheck.
# Built automatically on first use by ci/lint.sh.
FROM alpine:3.20

RUN apk add --no-cache shellcheck

WORKDIR /work
ENTRYPOINT ["shellcheck"]
