#!/usr/bin/env python3
"""Non-destructive tests of recovery helpers, using temporary directories only."""
import pathlib
import subprocess
import tempfile
import unittest

SOURCE = (pathlib.Path(__file__).resolve().parents[1] / 'pgsqlms-ha').read_text()
HELPERS = SOURCE[SOURCE.index('run_as_pg()'):SOURCE.index('\ncase ${1:-} in')]


class RecoveryTests(unittest.TestCase):
    def run_helper(self, script):
        with tempfile.TemporaryDirectory() as tmp:
            preamble = '''
set -uo pipefail
PGDATA="$ROOT/data"
RESCUE_DIR="$ROOT/rescue"
mkdir -p "$PGDATA/global" "$PGDATA/pg_wal" "$RESCUE_DIR"
printf control > "$PGDATA/global/pg_control"
printf wal > "$PGDATA/pg_wal/segment"
TAIL_BACKUP_TIMEOUT_SEC=10
MY_HOSTNAME=node2
ocf_log() { :; }
'''
            return subprocess.run(['bash', '-c', preamble + HELPERS + '\n' + script],
                                  env={'ROOT': tmp, 'PATH': '/usr/bin:/bin'},
                                  capture_output=True, text=True)

    def check(self, script):
        result = self.run_helper(script)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_archive_and_checksum(self):
        self.check('''
preserve_branch || exit 1
archive=$(find "$RESCUE_DIR" -name COMPLETE)
[[ -n $archive ]] || exit 2
cd "$(dirname "$archive")"
sha256sum -c SHA256SUMS || exit 3
mkdir "$ROOT/restored"
tar -xf pgdata.tar -C "$ROOT/restored"
cmp "$PGDATA/pg_wal/segment" "$ROOT/restored/pg_wal/segment"
''')

    def test_external_wal_rejected(self):
        self.check('''
ln -s "$ROOT" "$PGDATA/external"
if preserve_branch; then exit 1; fi
[[ -z $(find "$RESCUE_DIR" -name COMPLETE) ]]
''')

    def test_failed_copy_not_complete(self):
        self.check('''
tar() { return 1; }; export -f tar
if preserve_branch; then exit 1; fi
[[ -z $(find "$RESCUE_DIR" -name COMPLETE) ]]
''')

    def test_config_preserves_other_settings(self):
        self.check('''
PEER_R0_IP=10.0.0.1 PEER_R1_IP=10.1.0.1 DB_PORT=5432
REPL_USER=repl PGPASS_FILE=/tmp/pgpass MY_HOSTNAME=node2 MY_SLOT=node2
printf "work_mem = '8MB'\\n  primary_slot_name = 'wrong'\\n" > "$PGDATA/postgresql.auto.conf"
chown() { :; }
restore_local_auto_conf || exit 1
grep -q "work_mem = '8MB'" "$PGDATA/postgresql.auto.conf" || exit 2
[[ $(grep -c primary_slot_name "$PGDATA/postgresql.auto.conf") == 1 ]] || exit 3
[[ -f $PGDATA/standby.signal ]]
''')

    def test_all_shell_syntax(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        for name in ('pgsqlms-ha', 'setup-node.sh', 'configure-ha.sh',
                     'generate-ha-config.sh', 'validate-pgsqlms-ha.sh'):
            result = subprocess.run(['bash', '-n', str(root / name)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
