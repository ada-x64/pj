This is an org-level repo root, aka a "metarepo." It is not a git repository,
but a project-level working tree.

Various convenience scripts are at ~/repos/nanvix/.config. If you are in a
sandbox, this will not exist.

Git repositories in this directory are typically checked out as a bare +
worktree layout, but some less active repos are plain git clones.

Hidden directories are not part of the nanvix project but include personal
configuration.

When you enter a new directory, read _its_ AGENTS.md as well. They may also have
.github/copilot-instructions. Read these if they seem relevant.

Worktrees should have one of the following prefixes:

- feat/ # new features
- fix/ # bug fixes
- release/ # release branches - rare!
- doc/ # documentation
- tests/ # testing - new tests, test edits, etc.

The exception is the default branch, which is stored at .default-branch. You should not modify this branch, it is for reference only. Fetch and pull each time you reference it, so it always stays up to date.

If you are sandboxed, do NOT modify permissions. On the host, file owners are
v-phoenixman:agents. This should be reflected in the sandbox.

All worktrees should have relative git dirs. If you need to update git, then add
the ppa and do so.

Use the justfile for worktree management. Do NOT retarget 'active' unless specifically asked to do so.

---

The first thing you should do is to read AGENTS.local.md if it exists.
