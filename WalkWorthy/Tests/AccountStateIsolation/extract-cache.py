"""Compile the production cache methods without the network client's dependencies."""

from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
methods = []
for signature in ["static func makeDefaultSession()", "static func purgeLegacyHTTPResponseCache()"]:
    start = source.index(signature)
    opening = source.index("{", start)
    end, depth = opening + 1, 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    methods.append(source[start:end])

Path(sys.argv[2]).write_text("import Foundation\nfinal class LiveAPIClient {\n" + "\n".join(methods) + "\n}\n")
