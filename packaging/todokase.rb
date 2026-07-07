# Homebrew formula for the todokase CLI.
#
# This file is the canonical copy; the live version lives in the tap repo
# `RyanRusnak/homebrew-todokase` at `Formula/todokase.rb`. To publish:
#   1. packaging/build-cli-release.sh 0.38.0
#   2. gh release create cli-v0.38.0 dist/todokase-0.38.0-macos-universal.tar.gz
#   3. paste the printed sha256 below, copy this file into the tap repo, push.
#
# Install:  brew install RyanRusnak/todokase/todokase
class Todokase < Formula
  desc "Keyboard-first tasks from your terminal — todokase companion CLI"
  homepage "https://github.com/RyanRusnak/todarchy-ios"
  version "0.38.0"
  license "MIT"

  # Prebuilt universal (arm64 + x86_64) binary — Automerge is statically
  # linked, so nothing else needs bundling.
  url "https://github.com/RyanRusnak/todarchy-ios/releases/download/cli-v0.38.0/todokase-0.38.0-macos-universal.tar.gz"
  sha256 "a9a8ce66b8f66f461558e4855a0a3b62ba9d92ed6bb15351f2b50d50240aaa2a"

  def install
    bin.install "todokase"
  end

  test do
    assert_match "keyboard-first tasks", shell_output("#{bin}/todokase --help")
  end
end
