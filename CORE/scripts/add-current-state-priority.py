import os
from pathlib import Path

PACKAGE_ROOT = Path(__file__).resolve().parent.parent

paths = [
    PACKAGE_ROOT / 'super-memory-brain' / 'SKILL.md',
]
for skills_home in filter(None, [os.environ.get('ZCODE_HOME'), os.environ.get('CODEX_HOME')]):
    paths.append(Path(skills_home) / 'skills' / 'super-memory-brain' / 'SKILL.md')
block = '''## Current State Answer Priority

When asked `现在改了什么`, `当前状态`, `还记得吗`, `另一个会话`, `超级大脑进度`, or similar state/recall questions, answer in this order:

1. Read `CURRENT_BASELINE.md` first.
2. Read `manifest.json` for current version and module list.
3. Read `CHANGELOG.md` for recent changes.
4. Search package-local NexSandglass memory only after the files above.
5. Verify live files if the answer affects action.

Do not answer these questions from vague model memory alone.

'''
for path in paths:
    text = path.read_text(encoding='utf-8')
    if '## Current State Answer Priority' not in text:
        text = text.replace('## Package Shape\n', block + '## Package Shape\n')
    path.write_text(text, encoding='utf-8')
    print('updated', path)
