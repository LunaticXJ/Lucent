#!/usr/bin/env python3
"""Guard against shared sheet bindings being presented from multiple iOS tabs.
Static platform-branch check only; never starts the app or a device.
"""
from pathlib import Path
import re
path=Path(__file__).resolve().parents[1]/'Sources/LucentApp/LibraryView.swift'
source=path.read_text()
def ios_branch(text):
    active=True; stack=[]; output=[]
    def condition(expression):
        expression=re.sub(r'os\((\w+)\)',lambda m:'True' if m[1]=='iOS' else 'False',expression)
        expression=re.sub(r'targetEnvironment\([^)]*\)|canImport\([^)]*\)', 'False',expression)
        expression=re.sub(r'\bDEBUG\b','True',expression)
        return bool(eval(expression.replace('&&',' and ').replace('||',' or ').replace('!',' not ').strip(),{'__builtins__':{}},{}))
    for line in text.splitlines():
        token=line.strip()
        if token.startswith('#if '):
            match=condition(token[4:]);stack.append([active,match]);active=active and match
        elif token.startswith('#elseif '):
            parent,previous=stack[-1];match=not previous and condition(token[8:]);stack[-1][1]|=match;active=parent and match
        elif token=='#else':
            parent,previous=stack[-1];active=parent and not previous;stack[-1][1]=True
        elif token=='#endif': active=stack.pop()[0]
        elif active: output.append(line)
    assert not stack
    return '\n'.join(output)
ios=ios_branch(source)
keys=['showAddAddress','showSMB','showWebDAV','showJellyfin','showEmby','showPlex','showCloud','showDLNA','showProfiles','showTrakt','showProfileUnlock','showSourceChooser','showStorageManager','showBrowserUpload']
for name in keys:
    count=len(re.findall(r'\.sheet\(isPresented:\s*\$'+name+r'\b',ios))
    assert count==1,(name,count)
a=ios.index('    private var mobilePresentedShell:');b=ios.index('    private var mobileHomeTab:',a)
owner=ios[a:b]
for name in keys: assert re.search(r'\.sheet\(isPresented:\s*\$'+name+r'\b',owner),name
assert '.sheet' not in ios[ios.index('    private var mobileSettingsShell:'):ios.index('    private func selectMobileProfile')]
assert ios.count('.fileImporter(isPresented: $showFolderImporter')==1
assert ios.count('.fileImporter(isPresented: $showFileImporter')==1
assert 'onDismiss: performSourceAddition' in owner and 'onDismiss: finishStorageManagement' in owner
print('PASS: 14 iOS dialog bindings have exactly one stable owner, file importers are unique, source/storage transitions retain onDismiss sequencing')
