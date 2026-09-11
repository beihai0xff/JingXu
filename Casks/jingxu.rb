cask "jingxu" do
  version "0.4.0"
  sha256 "014af0f168ad597a135159db06fdb294a579cae6a28547666967b58907f2b1c7"

  url "https://github.com/beihai0xff/JingXu/releases/download/v#{version}/JingXu-0.4.0-test.19-macOS-arm64.dmg"
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
    JingXu 0.3.0 requires the new catalog format and does not migrate 0.2.x catalogs.
    Keep the matching older app to open existing 0.2.x catalogs; back up before upgrading.
  EOS
end
