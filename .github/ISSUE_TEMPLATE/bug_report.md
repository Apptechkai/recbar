---
name: Bug report
about: Something recorded wrong, crashed, or didn't work
---

**What happened**

**What you expected**

**How you started it**
- [ ] RecBar app
- [ ] `rec` CLI (command: `rec start ...`)

**Capture source**: entire display / window / app

**macOS version**:

**ffprobe output** (if the recording itself is wrong):

```
ffprobe -v error -show_entries stream=codec_type,codec_name,channels,duration -of compact <file>
```
