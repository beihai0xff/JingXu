cask "jingxu" do
  version "0.5.0"
  sha256 "8b2ce2c3f5efb6a4ecf5f6ac0db604a9cd860f86465553edf96a7ec5fc3c478e"

  url "https://github.com/beihai0xff/JingXu/releases/download/v#{version}/JingXu-0.5.0-test.26-macOS-arm64.dmg"
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
    JingXu 0.5.0 can migrate complete legacy v4 catalogs after making a backup.
    Unknown or incomplete catalog formats are rejected; back up before upgrading.
    Downgrading the app alone does not safely downgrade its catalog.
  EOS
end
