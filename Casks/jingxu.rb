cask "jingxu" do
  version "0.2.6"
  sha256 "17fc9cd648428e29553436266603754c87a0614efcdabee054ea29b61fa99f9f"

  url "https://github.com/beihai0xff/JingXu/releases/download/v#{version}/JingXu-#{version}-macOS-arm64.dmg"
  name "镜序"
  name "JingXu"
  desc "Offline camera photo catalog and organizer"
  homepage "https://github.com/beihai0xff/JingXu"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "镜序.app"

  caveats <<~EOS
    Quit JingXu and finish or safely cancel catalog tasks before upgrading.
    This build is ad-hoc signed and not notarized by Apple.
    Catalog data is kept outside the app; no catalog cleanup is performed.
  EOS
end
