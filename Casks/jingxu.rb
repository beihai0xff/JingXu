cask "jingxu" do
  version "0.2.7"
  sha256 "261bc92db9377ded3205affbdfc1eed8ceaa22a50211ae41a3fe413082da2ce5"

  url "https://github.com/beihai0xff/JingXu/releases/download/v#{version}/JingXu-0.2.7-test.16-macOS-arm64.dmg"
  name "镜序"
  name "JingXu"
  desc "Offline camera photo catalog and organizer"
  homepage "https://github.com/beihai0xff/JingXu"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "镜序.app"

  caveats <<~EOS
    Quit JingXu and finish or safely cancel catalog tasks before upgrading.
    This prerelease is ad-hoc signed and not notarized by Apple.
    Catalog data is kept outside the app; no catalog cleanup is performed.
  EOS
end
