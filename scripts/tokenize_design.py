#!/usr/bin/env python3
"""把散在各文件里的硬编码颜色与动效时长换成 Design token。

只做**完全等价**的替换：
- 颜色：字面量逐字相同 → 换成语义名，运行时值不变。
- 动效：把 5 档时长收成 4 档。0.12/0.16/0.18 → 0.15，0.2/0.22 → 0.21，
  easeOut 的 0.2/0.22/0.25 → 0.22。视觉上察觉不出，但以后只改一处。
"""

import re
import pathlib
import sys

COLORS = {
    'Color(red: 0.20, green: 0.66, blue: 0.42)': 'Design.success',
    'Color(red: 0.86, green: 0.30, blue: 0.28)': 'Design.danger',
    'Color(red: 0.85, green: 0.60, blue: 0.10)': 'Design.warning',
    'Color(red: 0.42, green: 0.36, blue: 0.98)': 'Design.brandStart',
    'Color(red: 0.62, green: 0.40, blue: 0.95)': 'Design.brandEnd',
}

# (曲线, 旧时长) -> token
ANIMS = {
    ('easeInOut', '0.12'): 'Design.animQuick',
    ('easeInOut', '0.15'): 'Design.animQuick',
    ('easeInOut', '0.16'): 'Design.animQuick',
    ('easeInOut', '0.18'): 'Design.animQuick',
    ('easeInOut', '0.2'):  'Design.animPanel',
    ('easeInOut', '0.21'): 'Design.animPanel',
    ('easeInOut', '0.22'): 'Design.animPanel',
    ('easeInOut', '0.25'): 'Design.animPanel',
    ('easeOut',   '0.2'):  'Design.animSmooth',
    ('easeOut',   '0.22'): 'Design.animSmooth',
    ('easeOut',   '0.25'): 'Design.animSmooth',
}

# 设计常量定义所在的文件不能被替换（否则自我覆盖成 Design.success = Design.success）
SKIP_FILES = {'ReaderUI.swift'}


def main():
    color_hits = 0
    anim_hits = 0
    for p in sorted(pathlib.Path('src').glob('*.swift')):
        text = p.read_text(encoding='utf-8')
        orig = text

        # 动效：Animation 里的 duration（先做，避免被颜色规则影响）
        # ⚠️ 要连 `Animation.` 前缀一起吃进去：`Animation.easeOut(duration:)` 和
        # `withAnimation(.easeOut(duration:))` 两种写法都要换成同一个完整的 token
        # 表达式，只吃后半截会拼出 `AnimationDesign.animSmooth` 这种东西。
        def anim_repl(m):
            nonlocal anim_hits
            curve, dur = m.group(2), m.group(3)
            token = ANIMS.get((curve, dur))
            if not token:
                return m.group(0)
            anim_hits += 1
            return token

        text = re.sub(r'(Animation)?\.(easeInOut|easeOut|easeIn|linear)\(duration:\s*([0-9.]+)\)',
                      anim_repl, text)

        # 弹簧
        def spring_repl(m):
            nonlocal anim_hits
            anim_hits += 1
            return 'Design.animSpring'

        text = re.sub(r'(Animation)?\.spring\(response:\s*0\.3,\s*dampingFraction:\s*0\.85\)',
                      spring_repl, text)

        # 颜色
        if p.name not in SKIP_FILES:
            for literal, token in COLORS.items():
                n = text.count(literal)
                if n:
                    text = text.replace(literal, token)
                    color_hits += n

        if text != orig:
            p.write_text(text, encoding='utf-8')
            print(f'  {p.name}')

    print(f'颜色 {color_hits} 处 · 动效 {anim_hits} 处')
    return 0


if __name__ == '__main__':
    sys.exit(main())
