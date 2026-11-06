#!/usr/bin/env python3
"""Compile the production credential formatter with synthetic inputs only."""
from pathlib import Path
import subprocess
import tempfile
source = Path('Sources/LucentApp/TMDBService.swift').read_text()
start = source.index('    private static func authorize(')
opening = source.index('{', start)
depth = 1
end = opening + 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
method = source[start:end].replace('private static func', 'static func', 1)
program = '''import Foundation
enum Subject {
''' + method + '''
}
@main struct Check {
 static func main() {
  let key = String(repeating: "a", count: 32)
  for value in [key, "  " + key + "\\n", "api_key: " + key, "Bearer " + key] {
   var url = URLComponents(string:"https://api.themoviedb.org/3/search/movie?language=en")!
   precondition(Subject.authorize(&url, credential:value) == nil)
   precondition(url.queryItems?.first(where: { $0.name == "api_key" })?.value == key)
   precondition(url.queryItems?.first(where: { $0.name == "language" })?.value == "en")
  }
  for value in ["test.read.token", "Bearer test.read.token", " bearer test.read.token "] {
   var url = URLComponents(string:"https://api.themoviedb.org/3/search/movie")!
   precondition(Subject.authorize(&url,credential:value) == "Bearer test.read.token")
  }
  print("PASS: API key, prefixed key, read token and pasted Bearer header normalization")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-tmdb-auth-') as folder:
    path = Path(folder)
    (path/'check.swift').write_text(program)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-parse-as-library', '-sdk', sdk, str(path/'check.swift'), '-o', str(path/'check')], check=True)
    subprocess.run([str(path/'check')], check=True)
