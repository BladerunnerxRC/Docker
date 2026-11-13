- Checkmk deployment state and next steps: see checkmk/HANDOFF-POC.md
- Host IPs/hardware for Checkmk: checkmk/HANDOFF-POC.local.md (gitignored, local only)
- Borg backup state, unmerged branches and next steps: see borg-backup/HANDOFF.md
- Portainer agent state and next steps: see portainer-agent/HANDOFF.md
- Portainer server URLs and agent host IPs: portainer-agent/HANDOFF.local.md (gitignored, local only)
- optiplex-docker → OptiPlex 3000 Micro migration plan and progress: see optiplex-docker-migration/PLAN.md

## Git branch naming
- Use descriptive branch names that say what the change is (e.g. `dev-checkmk-borg-backup`, `fix-checkmk-tz-crashloop`). No random/auto-generated names.
- Prefix `dev-` for planned enhancements and `fix-` for bug fixes.
