# shell-repo

My own custom shells repository — a collection of shell scripts, dotfiles, helpers, and small utilities I use to improve my terminal workflow.

> NOTE: This README is a general, comprehensive guide. Replace or extend sections to match the concrete scripts and files in this repository.

---

Table of Contents

- About
- Features
- Repository layout
- Installation
- Usage examples
- Configuration and customization
- Recommended tools & quality checks
- Contributing
- Testing & CI
- Security
- License
- Support

---

About

This repository contains personal shell utilities and configuration snippets meant to be reused across machines. Expect small programs (bash/zsh/fish scripts), helper tools, and dotfile fragments that automate repetitive terminal tasks, improve productivity, or demonstrate shell techniques.

Features

- Small, focused shell scripts that do one thing well
- Dotfile fragments and setup helpers for common shells (bash, zsh, fish)
- Installation helpers to add scripts to PATH and set executable permissions
- Documentation and examples for usage and customization

Repository layout (suggested)

The layout below is a recommended convention — actual top-level directories may vary. Update this section if your repo has different names.

- bin/          : User-facing scripts (addable to $PATH)
- scripts/      : Helper scripts, build/test utilities, one-off tools
- dotfiles/     : Shell configuration fragments (.bashrc, .zshrc, Fish config)
- completions/  : Shell completion scripts (bash_completion, zsh comps, fish)
- themes/       : Prompt/theme files (oh-my-zsh, starship snippets)
- docs/         : Additional documentation and usage examples
- examples/     : Example configs and usage scenarios
- tests/        : Small test scripts or integration checks

Installation

Minimal — clone and optionally add `bin/` to your PATH.

```bash
# clone the repo
git clone https://github.com/davindakhrisna/shell-repo.git
cd shell-repo

# make scripts executable (if needed)
chmod +x bin/* scripts/* || true

# add bin/ to your PATH (example for bash/zsh)
# add the following line to your ~/.bashrc or ~/.zshrc
export PATH="$HOME/path/to/shell-repo/bin:$PATH"
```

If you want to install a single script globally:

```bash
sudo cp bin/my-script /usr/local/bin/my-script
sudo chmod +x /usr/local/bin/my-script
```

Usage examples

Each script typically includes a brief usage header (run with `-h` or `--help`). Examples below are generic — replace with the specific script names from this repo.

```bash
# show help
bin/my-script --help

# run a small utility
bin/backup-dotfiles ~/dotfiles
```

Configuration & customization

- Dotfiles in `dotfiles/` are meant to be copied or symlinked to your home directory. Example using symlink:

```bash
ln -s $(pwd)/dotfiles/.zshrc ~/.zshrc
```

- For completions, follow your shell's installation instructions (source the file in your shell config or place it in the appropriate completions directory).

- Edit variables at the top of scripts if they provide USER/CONFIG stanzas.

Recommended tools & quality checks

- ShellCheck — static analysis for shell scripts. Install and run it locally:

```bash
# with apt
sudo apt-get install -y shellcheck
shellcheck bin/*.sh scripts/*.sh
```

- shfmt — format shell scripts for consistency.

Contributing

This is a personal repository but contributions and suggestions are welcome.

- If you open an issue, include the OS, shell, and the script name that caused the problem.
- For pull requests, follow these guidelines:
  - Provide a clear description of the change and reasoning
  - Keep changes focused and small
  - Add examples or updated docs for new functionality
  - Run ShellCheck and fix any warnings where reasonable

Testing & CI

If you add automated tests or linting, consider adding a small GitHub Actions workflow that runs ShellCheck and shfmt on pull requests. Example actions jobs:

- run shellcheck on changed scripts
- run shfmt to check formatting

Security

- Review scripts before running them, especially when they require sudo or operate on important files.
- Avoid running scripts from untrusted forks or contributors without inspection.
- Limit secrets in scripts; if a script needs credentials, prefer reading from environment variables or protected key stores rather than commiting secrets to the repo.

License

This repository currently does not include a LICENSE file. If you want a permissive license, add a LICENSE file (for example, the MIT License) and update this section. Example MIT header for files:

```
MIT License
Copyright (c) 2026 Your Name

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions: ...
```

Support & contact

If you need to reach the repository owner:

- GitHub: https://github.com/davindakhrisna

Changelog

Keep a simple CHANGELOG.md if you expect frequent changes. Use the Keep a Changelog format (https://keepachangelog.com) or a minimal date-based log.

Credits

- Built by davindakhrisna
- Based on common shell community practices and utilities

---

Customizing this README

Update the sections above to list the actual scripts, their usage examples, and any specific installation instructions for your environment. If you'd like, I can:

- Inspect the repository and generate a README that includes an index of the actual scripts and example usages (I can open files and extract usage headers).
- Create a LICENSE file for you (specify which license).

