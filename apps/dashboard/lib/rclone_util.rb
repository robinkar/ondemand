require "json"
require "open3"
require "pathname"

class RcloneUtil

  class << self
    def ls(remote, path)
      full_path = "#{remote}:#{path}"
      # Use lsjson for easy parsing and more info about files
      # Rclone can hang for >20 minutes if remote isn't available and low-level-retries isn't set
      o, e, s = rclone("lsjson", "--low-level-retries=1", full_path)
      if s.success?
        files = JSON.parse(o)
        files
      else
        raise "Error listing files: #{e}"
      end
    end

    def directory?(remote, path)
      # remote:/ will always be a directory
      if path.root?
        return true
      end
      # List directories in parent and check if requested directory is there
      full_path = "#{remote}:#{path.parent.to_s}"
      o, e, s = rclone( "lsf", "--low-level-retries=1", "--dirs-only", "--dir-slash=false", full_path)
      if s.success?
        o.lines.any?{ |l| l.strip == path.basename.to_s}
      else
        raise "Error checking info for path: #{e}"
      end
    end

    def mime_type(remote, path)
      # Check first is it is a directory, to avoid strange lsjson behaviour
      # when a directory contains a file with the same name as the directory.
      # `rclone lsjson remote:/name` and `rlcone lsjson remote:/name/name`
      # returns only the info for remote:/name/name
      if directory?(remote, path)
        "inode/directory"
      else
        files = ls(remote, path)
        files.find { |file| file["Path"] == path.basename.to_s }["MimeType"]
      end
    end

    def cat(remote, path, &block)
      full_path = "#{remote}:#{path}"
      # Read the file in 32kb chunks
      if block_given?
        run_popen(rclone_cmd, "cat", full_path) do |o|
          while data = o.read(32768)
            yield data
          end
        end
      else
        # Read the whole file
        o, e, s = rclone("cat", full_path)
        if s.success?
          o
        else
          raise "Error reading file #{full_path}: #{e}"
        end
      end
    end

    def remote_type(remote)
      # Get the rclone remote type (e.g. s3) for a single remote
      o, e, s = rclone("listremotes", "--long")
      if s.success?
        remote = o.lines.grep(/^#{Regexp.escape(remote)}:/).first
        return nil if remote.nil?

        type = remote.split(":")[1].strip
      else
        raise "Error getting information about remote: #{e}"
      end
    end

    def rclone_cmd
      # TODO: Handle Rclone dependency in some way
      ENV.fetch("OOD_RCLONE_PATH", "rclone")
    end

    def rclone(*args)
      Open3.capture3(rclone_cmd, *args)
    end

    def run_popen(cmd, *args, stdin_data: nil, &block)
      Open3.popen3(cmd, *args) do |i, o, e, t|
        if stdin_data
          i.write(stdin_data)
        end
        i.close

        err_reader = Thread.new { e.read }

        yield o

        o.close
        exit_status = t.value
        err = err_reader.value.to_s.strip
        if err.present? || !exit_status.success?
          raise "Rclone exited with status #{exit_status.exitstatus}\n#{err}"
        end
      end
    end
  end
end
