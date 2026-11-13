#!/usr/bin/env python3
"""通过隔离的 Tern 窗口验证侧边栏关闭行为。"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


TERN = shutil.which("tern")
PLUGIN_DIR = Path(__file__).resolve().parent


@unittest.skipUnless(
    TERN and os.environ.get("OMP_HISTORY_UI_TEST") == "1",
    "需要 Tern 和 OMP_HISTORY_UI_TEST=1；测试会打开隔离窗口",
)
class SidebarCloseTest(unittest.TestCase):
    """验证原生关闭按钮、顶部开关和标签关闭之间的关系。"""

    @classmethod
    def setUpClass(cls):
        """启动使用独立配置和守护进程的 Tern 窗口。"""
        cls.temp = tempfile.TemporaryDirectory(prefix="omp-history-test-", dir="/tmp")
        root = Path(cls.temp.name)
        config = root / "config"
        workspace = root / "workspace"
        (config / "plugin-data" / "omp-history").mkdir(parents=True)
        workspace.mkdir()
        (root / "agent" / "sessions").mkdir(parents=True)
        (config / "settings.json").write_text(
            json.dumps({"tabs": "Vertical", "pane_headers": "Split", "widgets": [{"id": "cpu"}]}),
            encoding="utf-8",
        )
        (config / "plugin-data" / "omp-history" / "kv.json").write_text(
            json.dumps({"visible": False, "default_hidden_v1": True}), encoding="utf-8"
        )
        cls.env = os.environ.copy()
        cls.env.update({
            "TERN_CONFIG_DIR": str(config),
            "TERN_DAEMON_SOCKET": str(root / "daemon.sock"),
            "PI_CODING_AGENT_DIR": str(root / "agent"),
        })
        cls.control = str(root / "control.sock")
        cls.workspace = str(workspace)
        cls.window = None
        cls.addClassCleanup(cls.cleanup_window)
        subprocess.run(
            [TERN, "plugin", "link", str(PLUGIN_DIR)], cwd=workspace, env=cls.env,
            check=True, capture_output=True, text=True, timeout=15,
        )
        cls.window = subprocess.Popen(
            [TERN, "--control", cls.control], cwd=workspace, env=cls.env,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if cls.window.poll() is not None:
                raise RuntimeError("隔离 Tern 窗口提前退出")
            try:
                result = cls.ctl("tree", '[title="显示/隐藏 OMP 会话历史"]')
                if result.get("count") == 1:
                    return
            except (OSError, subprocess.SubprocessError, json.JSONDecodeError):
                pass
            time.sleep(0.1)
        raise RuntimeError("隔离 Tern 窗口未加载历史插件")

    @classmethod
    def cleanup_window(cls):
        """关闭隔离窗口并删除临时文件。"""
        if cls.window and cls.window.poll() is None:
            try:
                cls.ctl("quit")
                cls.window.wait(timeout=10)
            except (OSError, subprocess.SubprocessError):
                cls.window.terminate()
                cls.window.wait(timeout=10)
        cls.temp.cleanup()

    @classmethod
    def ctl(cls, *args):
        """向隔离窗口发送控制命令并读取结果。"""
        result = subprocess.run(
            [TERN, "ctl", "--control", cls.control, *args], cwd=cls.workspace,
            env=cls.env, check=True, capture_output=True, text=True, timeout=15,
        )
        return json.loads(result.stdout)

    @classmethod
    def sidebar_count(cls):
        """统计隔离会话中所有标签的历史面板。"""
        result = subprocess.run(
            [TERN, "ls", "--json"], cwd=cls.workspace, env=cls.env,
            check=True, capture_output=True, text=True, timeout=15,
        )
        sessions = json.loads(result.stdout)["sessions"]
        return sum(
            block.get("title") == "OMP History"
            for session in sessions
            for tab in session.get("tabs", [])
            for block in tab.get("blocks", [])
        )

    def test_close_sidebar_stays_closed_and_tab_close_preserves_others(self):
        """关闭面板保持隐藏；关闭整个标签不影响其他标签。"""
        self.ctl("plugins", "run", "plugin.omp-history.toggle")
        self.ctl("tab", "new")
        self.ctl("wait", "1500")
        self.assertEqual(self.sidebar_count(), 2)

        self.ctl("tab", "close")
        self.ctl("wait", "1500")
        self.assertEqual(self.sidebar_count(), 1)

        self.ctl("tab", "new")
        self.ctl("wait", "1500")
        self.assertEqual(self.sidebar_count(), 2)
        self.ctl("click", 'header[title="OMP History"] .tn-close')
        self.ctl("wait", "2300")
        self.assertEqual(self.sidebar_count(), 0)

        self.ctl("click", '[title="显示/隐藏 OMP 会话历史"]')
        self.ctl("wait", "300")
        self.assertEqual(self.sidebar_count(), 1)


if __name__ == "__main__":
    unittest.main()
