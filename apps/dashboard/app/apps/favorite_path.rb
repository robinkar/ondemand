class FavoritePath
  def initialize(path, title:nil)
    @title = title || path.try(:title)
    @path = Pathname.new(path.to_s)
  end

  attr_accessor :path, :title

  REMOTE_REGEX = /^\/?[0-9A-Za-z_\.\- ]+:\//

  def remote?
    path.to_s.match(REMOTE_REGEX)
  end

  def to_s
    path.to_s
  end
end
