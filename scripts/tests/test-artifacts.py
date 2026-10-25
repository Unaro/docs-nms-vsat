#!/usr/bin/env python3
"""Artifact extraction and rendering tests. Never touches system configuration."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class ArtifactTests(unittest.TestCase):
    def test_shell_syntax(self):
        files = list(ROOT.glob('*.sh')) + list((ROOT / 'lib').glob('*.sh')) + list((ROOT / 'artifacts/bin').glob('*.sh'))
        for file in files:
            result = subprocess.run(['bash', '-n', str(file)], capture_output=True)
            self.assertEqual(result.returncode, 0, str(file) + str(result.stderr))

    def test_render_all_templates(self):
        import re
        for template in (ROOT / 'artifacts').rglob('*.tpl'):
            keys = set(re.findall(r'\$\{(\w+)\}', template.read_text()))
            with tempfile.TemporaryDirectory() as tmp:
                # Replace install in this shell only, so tests also run unprivileged.
                script = 'source "$1/lib/artifacts.sh"\ninstall() { cp -- "${@: -2:1}" "${@: -1}"; }\n'
                script += '\n'.join(f"{key}='value'" for key in keys)
                script += '\nrender_artifact "$2" "$3"\n'
                result = subprocess.run(['bash', '-eu', '-c', script, 'bash', str(ROOT),
                                         str(template.relative_to(ROOT / 'artifacts')), tmp + '/out'],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn('${', pathlib.Path(tmp + '/out').read_text())

    def test_missing_variable_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(['bash', '-c', 'source "$1/lib/artifacts.sh"; unset PGDATA; render_artifact systemd/cluster-boot-analyzer.service.tpl "$2"',
                                     'bash', str(ROOT), tmp + '/out'], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(pathlib.Path(tmp + '/out').exists())

    def test_installers_have_no_embedded_artifacts(self):
        for name in ('configure-ha.sh', 'bootstrap-ha.sh', 'setup-node.sh'):
            self.assertNotIn('<<', (ROOT / name).read_text())

    def test_application_stacks_are_independent_of_postgres(self):
        text = (ROOT / 'configure-ha.sh').read_text()
        constraints = [line for line in text.splitlines() if 'pcs constraint' in line]
        for line in constraints:
            if 'app-stack' in line or 'daemon-stack' in line:
                self.assertNotIn('pgsql', line)
        self.assertIn('pcs constraint order start haproxy-svc-clone then start app-stack', text)
        self.assertIn('pcs constraint order start haproxy-svc-clone then start daemon-stack', text)

    def test_preflight_does_not_mutate_pgdata(self):
        text = (ROOT / 'artifacts/bin/cluster-boot-analyzer.sh').read_text()
        for forbidden in ('pg_ctl', 'touch "$PGDATA', 'rm -f "$PGDATA', 'sed -i'):
            self.assertNotIn(forbidden, text)


if __name__ == '__main__':
    unittest.main()
