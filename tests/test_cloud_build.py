import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('build_cloud', ROOT/'scripts/build_cloud.py')
build = importlib.util.module_from_spec(spec)
spec.loader.exec_module(build)


class CloudBuildTests(unittest.TestCase):
    def test_sync_state_is_declared_loaded_and_rendered(self):
        html = build.build_cloud((ROOT/'index.html').read_text())
        self.assertIn("sourceScope='',syncedAt=null;", html)
        self.assertIn("sourceScope=data.source_scope||'';syncedAt=data.synced_at;render()", html)
        self.assertIn("${syncedAt?' · 同期 '+dt(syncedAt):''}", html)

    def test_required_transform_drift_and_duplicates_fail_before_output(self):
        html = (ROOT/'index.html').read_text()
        for anchor in ("let sessions=[],anchor=today(),warnings=[],sourceScope='';",
                       "sourceScope=data.source_scope||'';render()",
                       "${warnings.length?' · '+warnings.join(' / '):''}"):
            for changed in (html.replace(anchor, 'changed'), html + anchor):
                with self.subTest(anchor=anchor), self.assertRaisesRegex(ValueError, 'anchor mismatch'):
                    build.build_cloud(changed)


if __name__ == '__main__':
    unittest.main()
