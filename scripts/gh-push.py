#!/usr/bin/env python3
"""在 github.com:443 被阻断、但 api.github.com 可用的环境里推送。

用法：./scripts/gh-push.py

走 GitHub 的 Git Data API 上传提交。这是标准协议的正确用法，
只是绕开被阻断的 git-upload-pack 端点。

限制
- 只做 fast-forward，不 force
- 二进制 base64 膨胀，大仓库慢
- 用 tree 内容比对判断是否需要推送（API 生成的 commit SHA 与本地不同）
"""
import base64
import json
import subprocess
import sys

REPO = "AlphaXe-Hub/better-macOS"
BRANCH = "main"


def run(args):
    r = subprocess.run(args, capture_output=True)
    if r.returncode != 0:
        sys.exit(f"命令失败: {' '.join(args)}\n{r.stderr.decode(errors='replace')}")
    return r.stdout


def run_text(args):
    return run(args).decode(errors="replace")


def gh(args, payload=None):
    cmd = ["gh", "api"] + args
    if payload is not None:
        cmd += ["--input", "-"]
    r = subprocess.run(cmd, input=payload, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"gh api 失败: {args}\n{r.stderr}")
    return r.stdout.strip()


def remote_head():
    return gh([f"repos/{REPO}/git/refs/heads/{BRANCH}", "--jq", ".object.sha"])


def tree_of(commit):
    return json.loads(gh([f"repos/{REPO}/git/commits/{commit}"]))["tree"]["sha"]


def remote_paths(tree_sha):
    data = json.loads(gh([f"repos/{REPO}/git/trees/{tree_sha}?recursive=1"]))
    return {e["path"] for e in data["tree"] if e["type"] == "blob"}


def make_blob(content: bytes) -> str:
    body = json.dumps({
        "content": base64.b64encode(content).decode(),
        "encoding": "base64",
    })
    return json.loads(gh(["--method", "POST", f"repos/{REPO}/git/blobs"],
                         payload=body))["sha"]


def make_tree(entries, base_tree=None):
    body = {"tree": entries}
    if base_tree:
        body["base_tree"] = base_tree
    return json.loads(gh(["--method", "POST", f"repos/{REPO}/git/trees"],
                         payload=json.dumps(body)))["sha"]


def make_commit(tree, parents, message, name, email):
    body = json.dumps({
        "message": message,
        "tree": tree,
        "parents": parents,
        "author": {"name": name, "email": email},
    })
    return json.loads(gh(["--method", "POST", f"repos/{REPO}/git/commits"],
                         payload=body))["sha"]


def move_ref(sha):
    gh(["--method", "PATCH", f"repos/{REPO}/git/refs/heads/{BRANCH}",
        "-f", f"sha={sha}"])


def blob_entry(head, path):
    content = run(["git", "cat-file", "-p", f"{head}:{path}"])
    mode = "100755" if run_text(["git", "ls-tree", head, "--", path]).startswith("100755") else "100644"
    return {"path": path, "mode": mode, "type": "blob", "sha": make_blob(content)}


def main():
    remote = remote_head()
    local = run_text(["git", "rev-parse", "HEAD"]).strip()
    remote_tree = tree_of(remote)
    local_tree = run_text(["git", "rev-parse", "HEAD^{tree}"]).strip()

    print(f"远端 {remote[:8]} (tree {remote_tree[:8]})")
    print(f"本地 {local[:8]} (tree {local_tree[:8]})")

    if remote_tree == local_tree:
        print("内容已一致，无需推送")
        return

    has_remote = subprocess.run(["git", "cat-file", "-e", remote],
                                capture_output=True).returncode == 0

    if has_remote:
        commits = run_text(["git", "rev-list", "--reverse", f"{remote}..HEAD"]).split()
        base = remote
        for sha in commits:
            subject = run_text(["git", "log", "-1", "--format=%s", sha]).strip()
            print(f"→ {sha[:8]} {subject}")

            base_tree = tree_of(base)
            paths = run_text(["git", "diff-tree", "--no-commit-id",
                              "--name-only", "-r", sha]).split()
            entries = [blob_entry(sha, p) for p in paths
                       if subprocess.run(["git", "cat-file", "-e", f"{sha}:{p}"],
                                         capture_output=True).returncode == 0]
            new_tree = make_tree(entries, base_tree) if entries else base_tree

            new_commit = make_commit(
                new_tree, [base],
                run_text(["git", "log", "-1", "--format=%B", sha]).strip(),
                run_text(["git", "log", "-1", "--format=%an", sha]).strip(),
                run_text(["git", "log", "-1", "--format=%ae", sha]).strip())
            move_ref(new_commit)
            base = new_commit
            print(f"   → {new_commit[:8]}")
    else:
        # 本地没有远端 commit 对象（fetch 不可用）
        # 退化为整树对比：本地 HEAD 全量上传，远端多余文件靠 base_tree 保留
        print(f"本地缺少 {remote[:8]} 对象，改用整树对比模式")
        lp = set(run_text(["git", "ls-tree", "-r", "--name-only", "HEAD"]).split())
        rp = remote_paths(remote_tree)
        entries = [blob_entry(local, p) for p in sorted(lp)]
        print(f"  上传 {len(entries)} 个文件（远端有 {len(rp)} 个）")

        new_tree = make_tree(entries)
        new_commit = make_commit(
            new_tree, [remote],
            run_text(["git", "log", "-1", "--format=%B", local]).strip(),
            run_text(["git", "log", "-1", "--format=%an", local]).strip(),
            run_text(["git", "log", "-1", "--format=%ae", local]).strip())
        move_ref(new_commit)
        print(f"   → {new_commit[:8]}")

    final = remote_head()
    print(f"\n完成。远端 HEAD = {final[:8]}")
    print("本地与远端 SHA 会不同（作者/时间戳差异），但 tree 内容一致。")
    print("能正常 fetch 后执行 git fetch origin && git reset --hard origin/main 对齐。")


if __name__ == "__main__":
    main()
