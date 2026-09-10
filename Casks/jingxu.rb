cask "jingxu" do
  version "0.2.8"
  sha256 "899659c9dc1e4845262c201485c51cf98a9d799a247a95df34249ec008b4724f"

  url "https://github.com/beihai0xff/JingXu/releases/download/v#{version}/JingXu-0.2.8-test.17-macOS-arm64.dmg"
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
