import sys, re, pathlib
root = pathlib.Path(sys.argv[1]); names = sys.argv[2].split('+') if len(sys.argv) > 2 and sys.argv[2] else []
def edit(rel, old, new, count=1):
    p = root / rel; s = p.read_text()
    assert old in s, (rel, old[:60]); p.write_text(s.replace(old, new) if count == 0 else s.replace(old, new, count))
tile = 'Sources/Mosaic/ConversationTile.swift'
# Counters always.
edit(tile, '    var body: some View {\n        let prepared', '    var body: some View {\n        let _ = BenchCounters.hit(0)\n        let prepared')
s = (root / tile).read_text()
i = s.index('struct MessageBubble: View'); j = s.index('var body: some View {', i)
s = s[:j] + 'var body: some View {\n        let _ = BenchCounters.hit(1)' + s[j + len('var body: some View {'):]
k = s.index('struct ConversationTile: View'); m = s.index('var body: some View {', k)
s = s[:m] + 'var body: some View {\n        let _ = BenchCounters.hit(3)' + s[m + len('var body: some View {'):]
(root / tile).write_text(s)
edit('Sources/Mosaic/MediaViews.swift', '    var body: some View {\n        switch attachment.kind', '    var body: some View {\n        let _ = BenchCounters.hit(2)\n        switch attachment.kind')
for name in names:
    if name == 'nogeo':
        s = (root / tile).read_text()
        s = re.sub(r'\n\s*\.onGeometryChange\(for: CGRect\.self\) \{ proxy in proxy\.frame\(in: \.named\("thread"\)\) \} action: \{ frame in\n\s*registry\.update\(row\.id, frame\)\n\s*\}', '', s)
        (root / tile).write_text(s)
    elif name == 'nohover':
        edit('Sources/Mosaic/Controls.swift', '''        content
            .onHover { inside in inside && enabled ? push() : pop() }
            .onChange(of: enabled) { _, isEnabled in if !isEnabled { pop() } }
            .onDisappear { pop() }''', '        content')
        for rel in ['Sources/Mosaic/MediaViews.swift', 'Sources/Mosaic/ThreadDecorations.swift']:
            p = root / rel; p.write_text(p.read_text().replace('.help(', '.benchHelp('))
    elif name == 'noid':
        edit(tile, '                    .id(row.id)\n', '')
    elif name == 'noshadow':
        edit('Sources/Mosaic/WorkspaceView.swift', '.shadow(color: .black.opacity(dragging ? 0.2 : 0), radius: dragging ? 22 : 0, y: dragging ? 10 : 0)', '')
    elif name == 'noeffect':
        s = (root / tile).read_text()
        s = re.sub(r'\n\s*\.modifier\(NewMessageEffect\(animated: freshIDs\.contains\(row\.id\),\n\s*incoming: !row\.message\.isFromMe, reduceMotion: reduceMotion\)\)', '', s)
        (root / tile).write_text(s)
    else:
        raise SystemExit('unknown variant ' + name)
print('variant', names or ['base'])
