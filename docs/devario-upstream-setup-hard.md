# Devario kernel: repository setup and release workflow

How to set up a local copy of `Seafoam-Labs/linux` with read-only remotes for the kernel trees we take changes from. Every such remote fetches only the branches we explicitly list and no tags, which keeps the repository lean and our `devario-*` tags safe.

| Remote      | Tree                                                              | What we fetch                         |
|-------------|-------------------------------------------------------------------|---------------------------------------|
| `upstream`  | `https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git`  | `linux-X.Y.y` stable series            |
| `sched-ext` | `https://git.kernel.org/pub/scm/linux/kernel/git/tj/sched_ext.git`  | sched_ext development branches         |
| `arighi`    | `https://git.kernel.org/pub/scm/linux/kernel/git/arighi/linux.git`  | Andrea Righi's topic branches          |

`origin` is our own repository on GitHub and is the only remote we push to.

## Initial setup

```bash
git clone git@github.com:Seafoam-Labs/linux.git linux-devario
cd linux-devario
```

Every kernel.org remote is added the same way: add it, drop the default "fetch everything" refspec, disable tags and pruning. Use the helper below, or run the five commands by hand for each remote.

```bash
add_kernel_remote() {
    git remote add "$1" "$2"
    git config --unset-all "remote.$1.fetch"
    git config "remote.$1.tagOpt" --no-tags
    git config "remote.$1.pruneTags" false
    git config "remote.$1.prune" false
}

add_kernel_remote upstream  https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
add_kernel_remote sched-ext https://git.kernel.org/pub/scm/linux/kernel/git/tj/sched_ext.git
add_kernel_remote arighi    https://git.kernel.org/pub/scm/linux/kernel/git/arighi/linux.git
```

Then list the branches to track (see [Tracking a branch](#tracking-a-branch)) and fetch:

```bash
git config --add remote.upstream.fetch '+refs/heads/linux-7.2.y:refs/remotes/upstream/linux-7.2.y'
git config --add remote.upstream.fetch '+refs/heads/linux-6.18.y:refs/remotes/upstream/linux-6.18.y'
git config --add remote.sched-ext.fetch '+refs/heads/for-next:refs/remotes/sched-ext/for-next'

git config remotes.kernel 'upstream sched-ext arighi'
git remote update kernel
```

Order matters: a remote's configuration must be complete **before** its first fetch. A remote with no `fetch` lines is valid; fetching it simply does nothing until a branch is added.

The first fetch of `sched-ext` or `arighi` downloads every mainline commit between our stable base and that branch, so expect it to take noticeably longer than an `upstream` fetch. Later fetches are incremental.

## What each option does

`remote.<name>.fetch` is the list of branches we fetch from that remote, one line per branch. Without this restriction git would pull every branch the tree has; for the stable tree that means every `linux-*.y` branch going back to 2.6.

`remote.<name>.tagOpt --no-tags` disables fetching tags. The stable tree alone has more than five thousand, and tags share one global namespace, so tags from different trees could collide with each other and with ours.

`remote.<name>.pruneTags false` protects the `devario-*` tags. If someone has `fetch.pruneTags = true` set globally, fetching from kernel.org would pull all tags despite `--no-tags` and would also **delete every local tag that doesn't exist on that remote**, which means all of ours. This per-remote setting overrides the global configuration and must be set on **every** kernel.org remote; setting it on `upstream` does not protect fetches from `sched-ext` or `arighi`.

`remote.<name>.prune false` prevents remote-tracking refs from being removed during fetches. It guards against a global `fetch.prune = true`.

`remotes.kernel` defines a remote group, so `git remote update kernel` fetches all kernel.org remotes in one go without touching `origin`.

## Verification

```bash
git tag -l 'v*' | wc -l        # should be 0
git tag -l 'devario-*'         # our tags are in place
git branch -r                  # origin/*, upstream/*, sched-ext/*, arighi/*
git config --get-regexp '^remote\..*\.(fetch|tagopt|prunetags|prune)$'
```

Every kernel.org remote must show `tagopt --no-tags`, `prunetags false` and `prune false`. If a fetch prints `[new tag]` or `[deleted]` lines, the configuration of that remote is incomplete. Check `git config --show-origin --get-regexp prune`.

## Tracking a branch

### Finding the branch name

Branch names differ between trees and personal trees change often, so look before adding:

```bash
git ls-remote --heads sched-ext
git ls-remote --heads arighi
```

`ls-remote` only lists, it does not download anything.

### Adding the branch

One refspec line per branch, then fetch that remote:

```bash
git config --add remote.<remote>.fetch '+refs/heads/<branch>:refs/remotes/<remote>/<branch>'
git fetch <remote>
```

The line always follows the same pattern; the remote name and the branch name each appear twice:

```
+refs/heads/<branch>:refs/remotes/<remote>/<branch>
```

Examples:

```bash
# a new stable series
git config --add remote.upstream.fetch '+refs/heads/linux-7.3.y:refs/remotes/upstream/linux-7.3.y'

# a sched_ext branch
git config --add remote.sched-ext.fetch '+refs/heads/for-next:refs/remotes/sched-ext/for-next'

# one of Andrea's topic branches
git config --add remote.arighi.fetch '+refs/heads/<branch>:refs/remotes/arighi/<branch>'
```

Stable branch names use a dot (`linux-7.3.y`), not a hyphen.

`--add` is essential. Without it `git config` replaces all existing lines of that remote and only the new branch remains.

The leading `+` allows non-fast-forward updates. Development and personal branches are rebased regularly, and without the `+` such a fetch would be rejected.

### Removing a branch that is no longer used

```bash
git config --unset remote.upstream.fetch 'linux-6\.18\.y'
git update-ref -d refs/remotes/upstream/linux-6.18.y
```

The `--unset` argument is a regular expression matched against the value, hence the escaped dots. The same two commands work for any remote: replace `upstream` and the branch name.

## Day-to-day sync

```bash
git remote update kernel       # all kernel.org remotes
git fetch upstream             # or a single one
```

A plain `git fetch` fetches only `origin`.

Stable branches are fast-forward only, so `upstream/linux-X.Y.y` always points at the latest release of that series. Branches in `sched-ext` and `arighi` are **not**: they are rebased and occasionally deleted. After a rebase, `<remote>/<branch>` simply points at the new history; anything built from the old one has to be rebuilt as described in [Taking changes from development trees](#taking-changes-from-development-trees). A deleted branch keeps its last fetched state locally, because pruning is disabled; remove it with the commands above once it is no longer needed.

## Taking changes from development trees

Branches in `sched-ext` and `arighi` are based on mainline (`-rc` or `for-next`), not on our stable series. **Never merge them into a release branch**: a merge would bring in every mainline commit between the stable base and that branch.

Instead, carry the wanted commits on a local topic branch based on the stable tip, then merge that topic branch like any other.

List the commits that touch the relevant code and are not in our base:

```bash
git log --oneline --no-merges upstream/linux-7.2.y..sched-ext/for-next -- kernel/sched/ext* tools/sched_ext
```

Create the topic branch from the stable tip and cherry-pick with `-x`, which records the source commit in the message:

```bash
git switch -C 7.2/sched-ext upstream/linux-7.2.y
git cherry-pick -x <commit>...
```

Then merge it into the release branch with `--no-ff`, exactly as in the [release workflow](#release-workflow). It shows up under "Applied branches" like every other topic.

When the source branch has been rebased or has gained new commits, rebuild the topic branch the same way instead of cherry-picking on top of the old one. The topic branch is recreated from scratch on each stable point release anyway.

## Cutting a release with `tag-release.sh`

`tag-release.sh` tags the current `HEAD`, builds the changelog, and optionally pushes the tag and creates a GitHub release with a GPG-signed source tarball.

### Prerequisites

- A GPG signing key configured via `git config user.signingkey` (or `tag.gpgSign = true`).
- The GitHub CLI (`gh`) installed and authenticated with push access to `Seafoam-Labs/linux` (see below).
- A clean checkout of the release branch you want to tag, with `origin` pointing at `Seafoam-Labs/linux`.

### Setting up the GitHub CLI

The script uses `gh release create` to publish the release and upload the tarball and its signature. Without a working `gh`, the tag gets pushed but the release step fails.

Install it from your distribution's repositories:

```bash
sudo pacman -S github-cli      # Arch, CachyOS
sudo dnf install gh            # Fedora
sudo apt install gh            # Debian, Ubuntu
```

Log in once:

```bash
gh auth login
```

Pick **GitHub.com**, **SSH** as the preferred git protocol (matching our `git@github.com:` remote), and authenticate in the browser. `gh` requests the `repo` scope by default, which is what release creation needs.

Verify that you can see the repository and its releases:

```bash
gh auth status
gh release list --repo Seafoam-Labs/linux
```

If the second command fails with a "not found" error even though the repository exists, your account either lacks access to `Seafoam-Labs/linux` or the organization requires SSO authorization for the token. In the latter case, run `gh auth refresh` and approve access to the organization in the browser.

For headless or scripted environments, use a token instead of the interactive login. A classic token needs the `repo` scope; a fine-grained token needs **Contents: Read and write** on `Seafoam-Labs/linux`.

```bash
export GH_TOKEN=<token>        # or: gh auth login --with-token < token.txt
```

### How the changelog is built

The script looks for the upstream commit with the subject `Linux X.Y.Z` (for `.0` releases it falls back to `Linux X.Y`) in the history of `HEAD`. Everything on top of that commit is scanned on the **first-parent** line, and only merge commits whose subject starts with `Merge branch '<name>'` are recognized. Each such merge becomes one section under "Applied branches", listing the commits that the branch brought in.

This means:

- Topic branches **must be merged**, not squashed, cherry-picked or rebased onto the release branch. Squashed or cherry-picked work is invisible to the changelog.
- Merges must use `--no-ff`. If the topic sits directly on top of `Linux X.Y.Z`, a plain merge fast-forwards and creates no merge commit.
- Keep git's default merge message. A custom `-m` message or an edited subject will not match.
- Merge **local** branches. `git merge origin/foo` produces `Merge remote-tracking branch 'origin/foo'`, which the script ignores. Check the branch out locally first.

### Release workflow

Build the release branch from the upstream stable tip, merge the topic branches, verify, then tag:

```bash
git fetch upstream
git switch -C 7.2/base upstream/linux-7.2.y      # tip is "Linux 7.2.8"

# optional: keep topic branches fresh on the new base
git rebase --onto upstream/linux-7.2.y <old-base> 7.2/fixes

git switch 7.2/base
git merge --no-ff 7.2/fixes
git merge --no-ff 7.2/sched
# ...remaining topic branches

# verify what the changelog will contain
git log --first-parent --merges --oneline upstream/linux-7.2.y..HEAD

./tag-release.sh 7.2.8
```

Every line printed by the verification command must be of the form `Merge branch '...'`. If it prints nothing, "Applied branches" will be empty.

The version argument must match the `Linux X.Y.Z` commit the branch is based on. Tagging `7.2.8` on a branch based on `Linux 7.2.7` produces a changelog without any branches.

For every new stable point release, recreate the release branch from scratch as shown above rather than rebasing the existing one. The "Changes since" section compares releases by branch names and commit subjects, not hashes, so rebuilding does not break it.

### Re-spins

To publish a fixed build on the same upstream version, increase `pkgrel`:

```bash
./tag-release.sh 7.2.8 2        # devario-7.2.8-2
```

The previous release is detected automatically as the newest `devario-X.Y*` tag, so the changelog shows only what changed between the two builds.

### Interactive prompts

The script shows a changelog preview and asks twice:

1. `Create signed tag?` Answer `N` to abort without changes. This is a safe way to preview the changelog.
2. `Push tag and create GitHub release?` Answering `y` pushes the tag, builds `devario-<version>-<pkgrel>.tar.gz`, signs it, creates the GitHub release with the changelog as notes, and removes the temporary files.

If you answer `N` to the second prompt, the tag exists only locally. Pushing it later with `git push origin <tag>` does **not** create the GitHub release or the tarball. To redo the full flow, delete the local tag with `git tag -d <tag>` and run the script again.

### Fixing a bad release

If a release went out with a wrong changelog or wrong content, don't move the existing tag. Rebuild the branch and publish a re-spin with the next `pkgrel`.

## Don'ts

Don't use `git push --tags` or `git push --mirror` against `origin`; either would push every tag present locally. Don't merge `upstream/*`, `sched-ext/*`, `arighi/*` or `origin/*` branches directly into a release branch: `tag-release.sh` only recognizes merges of local branches (`Merge branch '...'`) when building the changelog, and merging a development tree would also pull in mainline history. Don't push to any kernel.org remote; they are read-only for us.
