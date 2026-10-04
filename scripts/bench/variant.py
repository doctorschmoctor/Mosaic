import sys, re, pathlib
root = pathlib.Path(sys.argv[1]); names = sys.argv[2].split('+') if len(sys.argv) > 2 and sys.argv[2] else []
def edit(rel, old, new, count=1):
    p = root / rel; s = p.read_text()
    assert old in s, (rel, old[:60]); p.write_text(s.replace(old, new) if count == 0 else s.replace(old, new, count))
tile = 'Sources/Mosaic/ConversationTile.swift'
# Counters always: the first `var body` after each struct declaration.
import glob
for index, struct in enumerate(['MessageList', 'MessageBubble', 'AttachmentView', 'ConversationTile', 'TileWorkspace']):
    for path in glob.glob(str(root / 'Sources/Mosaic/*.swift')):
        text = pathlib.Path(path).read_text()
        match = re.search(r'\bstruct ' + struct + r'\b[^{]*\{', text)
        if not match: continue
        j = text.index('var body: some View {', match.end())
        text = text[:j] + 'var body: some View {\n        let _ = BenchCounters.hit(%d)' % index + text[j + len('var body: some View {'):]
        pathlib.Path(path).write_text(text)
        break
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
    elif name in ('offset', 'visual'):
        move = ('.offset(x: held.minX - slot.minX, y: held.minY - slot.minY)' if name == 'offset'
                else '.visualEffect { [dx = held.minX - slot.minX, dy = held.minY - slot.minY] content, _ in content.offset(x: dx, y: dy) }')
        edit('Sources/Mosaic/WorkspaceView.swift', '        let frame = dragging ? (store.tileDrag?.frame ?? slot) : slot\n',
             '        let held = dragging ? (store.tileDrag?.frame ?? slot) : slot\n        let frame = CGRect(origin: slot.origin, size: held.size)\n')
        edit('Sources/Mosaic/WorkspaceView.swift', '            .id(chat.id)\n            .zIndex(dragging ? 100 : 1)',
             '            ' + move + '\n            .id(chat.id)\n            .zIndex(dragging ? 100 : 1)')
    else:
        raise SystemExit('unknown variant ' + name)
print('variant', names or ['base'])
