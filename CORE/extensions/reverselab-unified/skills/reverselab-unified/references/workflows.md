# Workflows

## PE Or Windows Sample

1. Confirm the user owns or is authorized to analyze the sample.
2. Prefer `mcp__reverse_lab_tools.sample_full_workup` if available.
3. If MCP is unavailable, use `open-reverselab` wrappers or scripts after status detection.
4. Generate reports under a local `reports` or `exports` directory.
5. Ask before debugger automation, patching, live execution, or network capture.

## APK Or Android App

1. Confirm the APK/app is owned, lab-provided, or authorized.
2. Check Android SDK/ADB/Frida availability.
3. Use knowledge-base routing for APK crypto/unpack patterns.
4. Ask before installing APKs, attaching Frida, or pulling app-private files.

## CTF Or Lab Website

1. Treat CTF/lab authorization as bounded to the challenge.
2. Use `kb_router` and `kb_read_file` for technique selection.
3. For browser-visible API exploration, use `browser-act-skill-forge`.
4. Do not apply techniques to third-party systems outside the lab scope.

## Website/API Behavior Reverse

Use `browser-act-skill-forge` when the task is to understand how a visible site loads data, reproduce a scraper, or build a reusable browser/API skill. Keep the workflow scoped to actions the user can manually perform in their browser.
