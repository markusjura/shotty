"""Write deterministic plain text for app-independent TextEdit scrolling checks."""

from pathlib import Path
import sys

output = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/Shotty-Text-Fixture.txt")
output.write_text("\n".join(
    f"TXT{row:04d}  Synthetic document row {row}: {(row * 2654435761) & 0xffffffff:08X}"
    for row in range(1, 301)
) + "\n", encoding="utf-8")
print(output)
