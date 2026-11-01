class Tart < Formula
  desc "Run macOS VMs on Apple silicon (BaneySpaces pin)"
  homepage "https://github.com/openai/tart"
  version "2.41.1"
  license "Fair Source"
  url "https://github.com/openai/tart/releases/download/2.41.1/tart.tar.gz"
  sha256 "e680a734febccfce7d4e910c1f7f13fc3b00f19a181c945e2d746de3214c32c2"
  depends_on "baneyspaces/pins/softnet"
  depends_on :macos

  def install
    libexec.install Dir["*"]
    bin.write_exec_script "#{libexec}/tart.app/Contents/MacOS/tart"
  end
end
