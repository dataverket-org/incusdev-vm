# Everything the Taskfile and bin/* need, for Homebrew on macOS and Linux:
#   brew bundle
# Supported: Apple silicon, Linux x86_64 and Linux arm64.
brew "go-task"                  # task: the runner, see Taskfile.yml
brew "lima"
brew "qemu" if OS.linux?        # what Lima runs the VM with; macOS uses its own framework
brew "incus"                    # the client only, for task incus-dash and the VM's API
brew "shellcheck"
