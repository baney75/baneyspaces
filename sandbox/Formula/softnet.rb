class Softnet < Formula
  desc "Software networking with isolation for Tart (BaneySpaces pin)"
  homepage "https://github.com/cirruslabs/softnet"
  version "0.25.0"
  license "Fair Source"
  url "https://github.com/openai/softnet/releases/download/0.25.0/softnet.tar.gz"
  sha256 "5a2e8ef779f0a2169b88d273ee806c0d64321ec7714c0dc99bf217523ae9b008"
  depends_on :macos

  def install
    bin.install "softnet"
  end
end
