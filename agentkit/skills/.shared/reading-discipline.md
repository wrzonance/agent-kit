# Reading discipline

An injected skill body is already authoritative context; never read its SKILL.md again.
Read each matched reference fully once per uninterrupted context, batching independent reads.
Never probe reference sizes (`wc -l`, `stat`, `head`) before reading. Start the read directly;
if output is truncated, continue from the last delivered section until the file is complete.
There is no size threshold to discover first. Reuse loaded content; after compaction, recover
only content missing from the preserved context or artifact. Do not preload unmatched references.

Use the manifest's exact paths. A missing path is a named manifest mismatch, not a reason to
search unrelated directories. Existing workflow-specific reading rules remain binding;
this shared rule grants no preliminary size-probe exception.
