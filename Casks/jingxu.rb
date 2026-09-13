cask "jingxu" do
  version "0.6.1"
  sha256 "1a791a9939ec1c7675062b084fff17a22f6d6ef796dd49ebe3b435198ab93e98"

  url "https://github.com/beihai0xff/JingXu/releases/download/v#{version}/JingXu-0.6.1-test.28-macOS-arm64.dmg"
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
    JingXu 0.6.1 can migrate complete legacy v4 catalogs after making a backup.
    Unknown or incomplete catalog formats are rejected; back up before upgrading.
    Downgrading the app alone does not safely downgrade its catalog.
  EOS
end
