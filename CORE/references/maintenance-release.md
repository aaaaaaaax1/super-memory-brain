# Maintenance And Direct Git Readiness

Use this cold route for explicit package maintenance, repository cleanup, or
privacy review. The live source tree is the only publication truth; do not
create a separate share/export directory.

Readiness requires:

- current source verification and CI evidence;
- current install/UI regression evidence after installer or UI changes;
- a privacy scan over the source files that are eligible for Git;
- `.gitignore` coverage for local memory, archives, runtime state, caches,
  credentials, and generated output.

Destructive deletion, broad overwrites, global rewrites, and private-memory
handling require exact user authorization. Keep rollback evidence in the local
private archive; never stage it for Git.
