# Devario kernel: repository setup and release workflow

How to set up a local copy of `Seafoam-Labs/linux` with an `upstream` remote pointing at the kernel.org stable tree. The configuration fetches only selected `linux-X.Y.y` branches from upstream and no tags, which keeps the repository lean and our `devario-*` tags safe.

## Initial setup

```bash
git clone git@github.com:Seafoam-Labs/linux.git linux-devario
cd linux-devario

git remote add upstream https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git
git config --unset-all remote.upstream.fetch
git config --add remote.upstream.fetch '+refs/heads/linux-7.2.y:refs/remotes/upstream/linux-7.2.y'
git config --add remote.upstream.fetch '+refs/heads/linux-6.18.y:refs/remotes/upstream/linux-6.18.y'
git config remote.upstream.tagOpt --no-tags
git config remote.upstream.pruneTags false
git config remote.upstream.prune false

git fetch upstream
```

Order matters: the entire `upstream` configuration must be in place **before** the first `git fetch upstream`.

## What each option does

`remote.upstream.fetch` is the list of branches we fetch from kernel.org, one line per stable series. Without this restriction git would pull every `linux-*.y` branch going back to 2.6.

`remote.upstream.tagOpt --no-tags` disables fetching tags from kernel.org. There are more than five thousand of them and we don't need any.

`remote.upstream.pruneTags false` protects the `devario-*` tags. If someone has `fetch.pruneTags = true` set globally, fetching from kernel.org would pull all tags despite `--no-tags` and would also **delete every local tag that doesn't exist on kernel.org**, which means all of ours. This per-remote setting overrides the global configuration.

`remote.upstream.prune false` prevents remote-tracking refs from being removed during upstream fetches. It guards against a global `fetch.prune = true`.

## Verification

```bash
git tag -l 'v*' | wc -l        # should be 0
git tag -l 'devario-*'         # our tags are in place
git branch -r                  # origin/* + upstream/linux-7.2.y, upstream/linux-6.18.y
git config --get-all remote.upstream.fetch
```

If `git fetch upstream` prints `[new tag]` or `[deleted]` lines, the configuration is incomplete. Check `git config --show-origin --get-regexp prune`.

## Adding another stable series

When we start working on a new series, e.g. 7.3, add one refspec line and fetch:

```bash
git config --add remote.upstream.fetch '+refs/heads/linux-7.3.y:refs/remotes/upstream/linux-7.3.y'
git fetch upstream
```

The line always follows the same pattern; only the version number changes, in both places:

```
+refs/heads/linux-X.Y.y:refs/remotes/upstream/linux-X.Y.y
```

The branch name uses a dot (`linux-7.3.y`), not a hyphen.

`--add` is essential. Without it `git config` replaces all existing lines and only the new branch remains.

## Removing a series that is no longer used

```bash
git config --unset remote.upstream.fetch 'linux-6\.18\.y'
git update-ref -d refs/remotes/upstream/linux-6.18.y
```

The `--unset` argument is a regular expression matched against the value, hence the escaped dots.

## Day-to-day sync

```bash
git fetch upstream
```

Stable branches are fast-forward only, so `upstream/linux-X.Y.y` always points at the latest release of that series.

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

Don't use `git push --tags` or `git push --mirror` against `origin`; either would push every tag present locally. Don't merge `upstream/*` or `origin/*` branches directly into a release branch: `tag-release.sh` only recognizes merges of local branches (`Merge branch '...'`) when building the changelog.
