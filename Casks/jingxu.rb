cask "jingxu" do
  version "0.2.5"
  sha256 "4be505e9efa23e0fec61fccf7b96d157929a325c04799eeba669c38f342af73a"

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
