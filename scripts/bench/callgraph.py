import re, sys
# Prints the main thread's call graph from a `sample` report, keeping frames with at least
# `minimum` samples, indented by depth, names shortened.
path, minimum = sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 80
lines = open(path, errors='replace').read().split('\n')
start = next(i for i, l in enumerate(lines) if 'Main Thread' in l)
out = []
for line in lines[start:]:
    if line.strip() == '' or (line.startswith('    ') and 'Thread_' in line and line is not lines[start]):
        if out: break
    m = re.match(r'^(\s*[+!:| ]*)(\d+) (.*)$', line)
    if not m: continue
    depth = len(m.group(1)); count = int(m.group(2))
    if count < minimum: continue
    name = re.sub(r'\s+\(in ([^)]+)\).*$', r'  [\1]', m.group(3))
    name = re.sub(r'<[^<>]*>', '', name)[:150]
    out.append('%s%d %s' % (' ' * (depth // 2), count, name))
print('\n'.join(out[:400]))
