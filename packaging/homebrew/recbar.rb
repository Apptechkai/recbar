# Homebrew formula for a tap, e.g. github.com/Apptechkai/homebrew-recbar
# Install: brew tap Apptechkai/recbar && brew install recbar
class Recbar < Formula
  desc "Headless meeting recorder for macOS: screen + separate audio tracks, no cloud, no overlay"
  homepage "https://github.com/Apptechkai/recbar"
  url "https://github.com/Apptechkai/recbar/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "REPLACE_WITH_TARBALL_SHA256"
  license "MIT"
  head "https://github.com/Apptechkai/recbar.git", branch: "main"

  depends_on :macos => :sequoia
  depends_on "ffmpeg"
  depends_on "whisperkit-cli" => :recommended

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/rec"
    system "make", "app", "SIGN=-"
    prefix.install "RecBar.app"
  end

  def caveats
    <<~EOS
      The menu bar / Dock app was built at:
        #{opt_prefix}/RecBar.app
      Copy it to /Applications:
        cp -R #{opt_prefix}/RecBar.app /Applications/

      On first run, grant Screen & System Audio Recording and Microphone
      permission to RecBar (and to your terminal for `rec`) in
      System Settings → Privacy & Security.
    EOS
  end

  test do
    assert_match "rec start", shell_output("#{bin}/rec 2>&1", 64)
  end
end
