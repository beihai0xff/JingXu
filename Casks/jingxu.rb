cask "jingxu" do
  version "0.9.2"
  sha256 "914dc90c31b5caeeb81f380f11f946de6a55e18b8ec7221e96a639a09aa09e85"

  url "https://github.com/beihai0xff/JingXu/releases/download/v#{version}/JingXu-0.9.2-test.36-macOS-arm64.dmg"
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
    JingXu 0.9.2 can migrate complete legacy v4 catalogs after making a backup.
    Unknown or incomplete catalog formats are rejected; back up before upgrading.
    Downgrading the app alone does not safely downgrade its catalog.
  EOS
end
