# Be sure to restart your server when you modify this file.

# Version of your assets, change this if you want to expire all your assets.
Rails.application.config.assets.version = '1.0'

# All static files from plugins get precompiled on first hit and we're OK with that
(ASUtils.find_local_directories("frontend/assets") + [QSAShared.js_dir]).each do |dir|
  ["**/*.js", "**/*.css", "**/*.jpg", "**/*.png", "**/*.erb"].each do |pattern|
    Dir.glob(File.join(dir, pattern)).each do |file|
      Rails.application.config.assets.precompile << File.basename(file).gsub(/.erb/, "")
    end
  end
end
