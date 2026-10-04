#!/usr/bin/env python3
"""把弃用的 onChange(of:perform:) 迁到 macOS 14 的两参数/零参数写法。

旧：.onChange(of: x) { v in ... }      （v 是**新值**）
新：.onChange(of: x) { _, v in ... }   /  .onChange(of: x) { ... }（不看值时）

只处理紧跟在 `onChange(of: …)` 后面的闭包头，别的地方的 `{ _ in }` 一概不碰。
"""

import re
import sys
import pathlib

PAT = re.compile(r'(\.onChange\(of:[^()]*\))(\s*)\{\s*(_|[A-Za-z_][A-Za-z0-9_]*)\s+in')


def migrate(text: str):
    count = 0

    def repl(m):
        nonlocal count
        head, ws, param = m.group(1), m.group(2), m.group(3)
        count += 1
        if param == '_':
            # 不关心新旧值 → 用零参数闭包，直接把 `_ in` 丢掉
            return f'{head}{ws}{{'
        # 旧 API 传给闭包的是新值，所以放到第二个参数上
        return f'{head}{ws}{{ _, {param} in'

    out = PAT.sub(repl, text)
    return out, count


def main():
    total = 0
    for p in sorted(pathlib.Path('src').glob('*.swift')):
        src = p.read_text(encoding='utf-8')
        new, n = migrate(src)
        if n:
            p.write_text(new, encoding='utf-8')
            print(f'  {p}: {n} 处')
            total += n
    print(f'共迁移 {total} 处')
    return 0 if total else 1


if __name__ == '__main__':
    sys.exit(main())
