#!/usr/bin/env python3
"""读取 OMP 会话头部，生成侧边栏所需的本地索引。"""

import json
import os
from pathlib import Path
import sys


def main():
    """扫描会话文件并输出标题、工作目录和最后修改时间。"""
    agent_dir = Path(os.environ.get("PI_CODING_AGENT_DIR", Path.home() / ".omp" / "agent"))
    sessions_dir = agent_dir / "sessions"
    if not sessions_dir.is_dir():
        raise FileNotFoundError(f"会话目录不存在: {sessions_dir}")

    rows = []
    for path in sessions_dir.glob("*/*.jsonl"):
        try:
            title = ""
            cwd = ""
            session_id = ""
            with path.open("rb") as stream:
                # 新版 OMP 的标题和 session 头位于文件开头；限制行长避免读取正文。
                for _ in range(4):
                    line = stream.readline(1024 * 1024)
                    if not line or not line.endswith(b"\n"):
                        break
                    entry = json.loads(line)
                    if entry.get("type") == "title":
                        title = entry.get("title") or title
                    elif entry.get("type") == "session":
                        cwd = entry.get("cwd") or ""
                        session_id = entry.get("id") or ""
                        break
            if not session_id:
                continue
            rows.append({"id": session_id, "title": title or "未命名会话", "cwd": cwd,
                         "path": str(path), "updated": path.stat().st_mtime})
        except (OSError, ValueError, TypeError, AttributeError):
            continue
    rows.sort(key=lambda row: row["updated"], reverse=True)
    json.dump(rows, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
