# Devario kernel: repository and stable upstream setup

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

## Don'ts

Don't use `git push --tags` or `git push --mirror` against `origin`; either would push every tag present locally. Don't merge `upstream/*` or `origin/*` branches directly into a release branch: `tag-release.sh` only recognizes merges of local branches (`Merge branch '...'`) when building the changelog.
