"""Launches the conda postgres closure as an itest service executable.

Mirrors the runtime wrapper from rules_itest's mysql example: the generated
shell script ensures $TMPDIR/pgdata exists (running initdb on first start),
drops root privileges like e2e/conda does (postgres refuses to run as root),
then execs postgres. Extra service `args` (e.g. the autoassigned `-p` port)
are forwarded via "$@".

The conda backend exposes a single `:tool` wrapper that dispatches to the
conda prefix's `bin/` via its first argument, so both `initdb` and
`postgres` are reached through the one `tool` label.
"""

def _postgres_server_impl(ctx):
    tool = ctx.executable.tool
    out = ctx.actions.declare_file(ctx.label.name)
    content = """#!/bin/sh
set -eu
TOOL="{tool_short}"
PGDATA="${{TMPDIR:-/tmp}}/pgdata"
SOCKDIR="${{SOCKET_DIR:-/tmp}}"

if [ "$(id -u)" = "0" ]; then
  NOBODY_USER="nobody"
  NOBODY_GID="$(id -g "$NOBODY_USER" 2>/dev/null || echo 65534)"
  mkdir -p "${{TMPDIR:-/tmp}}" "$SOCKDIR"
  if [ -d "$PGDATA" ]; then
    chown -R "$NOBODY_USER:$NOBODY_GID" "$PGDATA" 2>/dev/null || chown -R "$NOBODY_USER" "$PGDATA" || true
  fi
  chown "$NOBODY_USER:$NOBODY_GID" "${{TMPDIR:-/tmp}}" 2>/dev/null || chown "$NOBODY_USER" "${{TMPDIR:-/tmp}}" || true
  chown "$NOBODY_USER:$NOBODY_GID" "$SOCKDIR" 2>/dev/null || chown "$NOBODY_USER" "$SOCKDIR" || true
  export HOME="${{TMPDIR:-/tmp}}"
  if command -v setpriv >/dev/null 2>&1; then
    exec setpriv "--reuid=$NOBODY_USER" "--regid=$NOBODY_GID" --clear-groups "$0" "$@"
  elif command -v runuser >/dev/null 2>&1; then
    exec runuser -u "$NOBODY_USER" -- "$0" "$@"
  fi
  for d in /usr/bin /usr/sbin /sbin /bin; do
    if [ -x "$d/setpriv" ]; then
      exec "$d/setpriv" "--reuid=$NOBODY_USER" "--regid=$NOBODY_GID" --clear-groups "$0" "$@"
    fi
    if [ -x "$d/runuser" ]; then
      exec "$d/runuser" -u "$NOBODY_USER" -- "$0" "$@"
    fi
  done
  echo "running as root without setpriv/runuser to drop privileges" >&2
  exit 1
fi

if [ ! -d "$PGDATA" ]; then
  mkdir -p "$PGDATA"
  "$TOOL" initdb -D "$PGDATA" -U postgres --auth=trust --no-locale -E UTF8
fi

exec "$TOOL" postgres -D "$PGDATA" -c "listen_addresses=127.0.0.1" -c "unix_socket_directories=$SOCKDIR" "$@"
""".format(
        tool_short = tool.short_path,
    )
    ctx.actions.write(output = out, content = content, is_executable = True)
    runfiles = ctx.runfiles(files = [out])
    runfiles = runfiles.merge(ctx.attr.tool[DefaultInfo].default_runfiles)
    return [DefaultInfo(executable = out, runfiles = runfiles)]

postgres_server = rule(
    implementation = _postgres_server_impl,
    attrs = {
        "tool": attr.label(executable = True, cfg = "target", mandatory = True),
    },
    executable = True,
)
