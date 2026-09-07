# Auto-VC: 24/7 Automated Git Version Control Daemon

Auto-VC is a lightweight, zero-dependency background daemon designed to continuously monitor your NixOS configuration repository, automatically staging modified/added/deleted files, creating structured commits, and pushing changes to GitHub 24/7 using your dedicated deploy key.

---

## Features

- ⚡ **24/7 Continuous Monitoring:** Periodically checks your repository on a configurable interval (default: 60 seconds).
- 📦 **Automated Staging & Commits:** Detects uncommitted changes, stages all files (`git add -A`), and writes structured commit messages detailing changed files.
- 🚀 **Resilient Pushing:** Pulls upstream changes with rebase before pushing to avoid merge conflicts and non-fast-forward push rejections.
- 🔑 **Deploy Key Native:** Works seamlessly with your dedicated GitHub deploy key (`~/.ssh/id_github_deploy`) with zero browser logins, 2FA prompts, or expired tokens.

---

## Usage

### Manual CLI Commands

```bash
# Run one sync cycle and exit immediately
./auto-vc.sh --run-once

# Check current repository status and unpushed commits
./auto-vc.sh --status

# Preview what would be committed without pushing
./auto-vc.sh --dry-run

# Start in persistent 24/7 daemon loop (interval 60 seconds)
./auto-vc.sh --daemon --interval 60
```

---

## ⚙️ NixOS Integration

Auto-VC is integrated directly into the `homelab.shellRepo` module suite. In `hosts/homelab/default.nix`:

```nix
homelab.shellRepo = {
  enable = true;
  autoVc = {
    enable = true;
    repoPath = "/home/kryisnn/.config/flint"; # Target repository to monitor
    intervalSeconds = 60;                    # Check frequency
    user = "kryisnn";
  };
};
```

This creates a hardened, self-healing systemd service (`auto-vc.service`) that autostarts on boot and restarts automatically if terminated.
