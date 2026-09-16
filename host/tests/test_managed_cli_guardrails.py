from __future__ import annotations
import os
import stat
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch
from floweroll_host.managed_cli import ManagedJSONCLI
from floweroll_host.function_execution_worker import FunctionToolError

class ManagedCLIGuardrailTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
    def runner(self,source,**kw):
        path=self.root/'provider-cli'
        path.write_text('#!/usr/bin/env python3\n'+source)
        path.chmod(path.stat().st_mode|stat.S_IXUSR)
        return ManagedJSONCLI(path,cwd=self.root,**kw)
    def test_exit_zero_business_failure_is_not_success(self):
        for field in ['ok','success']:
            cli=self.runner('import json\nprint(json.dumps({"'+field+'":False,"error":{"subtype":"token_expired","message":"expired"}}))\n')
            with self.assertRaises(FunctionToolError) as ctx: cli.run_json([])
            self.assertEqual(ctx.exception.error_kind,'terminal')
            self.assertEqual(ctx.exception.output['cli_exit_code'],0)
            self.assertTrue(ctx.exception.output['business_error'])
    def test_ambient_api_keys_are_not_inherited(self):
        cli=self.runner('import json,os\nprint(json.dumps({"leaked":"HOST_TEST_SECRET_KEY" in os.environ,"cwd":os.getcwd()}))\n')
        with patch.dict(os.environ,{'HOST_TEST_SECRET_KEY':'test-only-never-inherit'}): result=cli.run_json([])
        self.assertFalse(result['data']['leaked']);self.assertEqual(result['data']['cwd'],str(self.root.resolve()))
    def test_output_is_bounded_while_process_is_running(self):
        cli=self.runner('import sys,time\nsys.stdout.write("x"*20000);sys.stdout.flush();time.sleep(20)\n',max_output_bytes=1000)
        start=time.monotonic()
        with self.assertRaises(FunctionToolError) as ctx: cli.run_json([])
        self.assertEqual(ctx.exception.error_kind,'model_correctable');self.assertLess(time.monotonic()-start,5)
    def test_timeout_reclaims_process(self):
        cli=self.runner('import time\ntime.sleep(20)\n',timeout_seconds=0.15)
        with self.assertRaises(FunctionToolError) as ctx: cli.run_json([])
        self.assertEqual(ctx.exception.error_kind,'transient')
    def test_non_json_or_truncated_json_never_verifies(self):
        cli=self.runner('print("not json")\n')
        with self.assertRaises(FunctionToolError):cli.run_json([])
    def test_echoed_provider_secret_is_redacted(self):
        cli=self.runner('import json,os\nprint(json.dumps({"ok":False,"message":"Bearer abc.token "+os.environ["PROVIDER_TOKEN"]}))\n',extra_env={'PROVIDER_TOKEN':'unit-test-value'})
        with self.assertRaises(FunctionToolError) as ctx: cli.run_json([])
        self.assertNotIn('unit-test-value',str(ctx.exception));self.assertNotIn('abc.token',str(ctx.exception))
