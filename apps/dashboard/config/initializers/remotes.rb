require "ood_files_app"
require "rclone_util"

begin
  OodFilesApp.candidate_favorite_paths.tap do |paths|
    remotes = RcloneUtil.remotes
    paths.concat remotes.map { |r| FavoritePath.new("/#{r}:/", title: r) }
  end
rescue => e
  Rails.logger.error("Error getting rclone remotes: #{e}")
end
