class FilesController < ApplicationController
  # include ActionController::Live
  include ZipTricks::RailsStreaming

  def fs
    request.format = 'json' if request.headers['HTTP_ACCEPT'].split(',').include?('application/json')

    @path = parse_path

    validate_path!

    if @path.directory?
      @path.raise_if_cant_access_directory_contents

      request.format = 'zip' if params[:download]

      respond_to do |format|

        format.html do
          render :index
        end

        format.json do
          if params[:can_download]
            # check to see if this directory can be downloaded as a zip
            can_download, error_message = @path.can_download_as_zip?
            render json: { can_download: can_download, error_message: error_message }
          else
            @files = @path.ls
            render :index
          end
        end

        # FIXME: below is a large block that should be moved to a model
        # if moved to a model the exceptions can be handled there and
        # then this code will be simpler to read
        # and we can avoid rescuing in a block so we can reintroduce
        # the block braces which is the Rails convention with the respond_to formats.
        format.zip do
          can_download, error_message = @path.can_download_as_zip?

          if can_download
            zipname = @path.basename.to_s.gsub('"', '\"') + '.zip'
            response.set_header 'Content-Disposition', "attachment; filename=\"#{zipname}\""
            response.set_header 'Content-Type', 'application/zip'
            response.set_header 'Last-Modified', Time.now.httpdate
            response.sending_file = true
            response.cache_control[:public] ||= false

            # FIXME: strategy 1: is below, use zip_tricks
            # strategy 2: use actual zip command (likely much faster) and ActionController::Live
            zip_tricks_stream do |zip|
              @path.files_to_zip.each do |file|
                begin
                  if File.file?(file.path) && File.readable?(file.path)
                    zip.write_deflated_file(file.relative_path.to_s) do |zip_file|
                      IO.copy_stream(file.path, zip_file)
                    end
                  end
                rescue => e
                  logger.warn("error writing file #{file.path} to zip: #{e.message}")
                end
              end
            end
          else
            logger.warn "unable to download directory #{@path.to_s}: #{error_message}"
            response.set_header 'X-OOD-Failure-Reason', error_message
            head :internal_server_error
          end
        rescue => e
          # Third party API requests (from outside of OnDemand) will see this error
          # message if there's an error while downloading a directory.
          # 
          # The client side code in the Files App performs checks before downloading
          # a directory with the ?can_download query parameter but other implementations
          # that don't perform this check will see HTTP 500 returned and the error
          # error message will be in the "X-OOD-Failure-Reason" header.
          #
          Rails.logger.warn "exception raised when attempting to download directory #{@path.to_s}: #{e.message}"
          response.set_header 'X-OOD-Failure-Reason', e.message
          head :internal_server_error
        end
      end
    else
      show_file
    end
  rescue => e
    @files = []
    flash.now[:alert] = "#{e.message}"

    logger.error(e.message)

    respond_to do |format|
      format.html {
        render :index
      }
      format.json {
        @files = []

        render :index
      }
    end
  end

  # PUT - create or update
  def update
    @path = PosixFile.new(normalized_path)

    validate_path!

    if params.include?(:dir)
      @path.mkdir
    elsif params.include?(:file)
      @path.mv_from(params[:file].tempfile)
    elsif params.include?(:touch)
      @path.touch
    else
      content = request.body.read

      # forcing utf-8 because File.write seems to require it. request bodies are
      # in ASCII-8BIT and need to be re encoded otherwise errors are thrown.
      # see test cases for plain text, utf-8 text, images and binary files
      content.force_encoding('UTF-8')

      @path.write(content)
    end

    render json: {}
  rescue => e
    render json: { error_message: e.message }
  end

  # POST
  def upload
    upload_path = uppy_upload_path
    @path = PosixFile.new(upload_path)

    validate_path!

    @path.handle_upload(params[:file].tempfile)

    render json: {}
  rescue AllowlistPolicy::Forbidden => e
    render json: { error_message: e.message }, status: :forbidden
  rescue Errno::EACCES => e
    render json: { error_message: e.message }, status: :forbidden
  rescue => e
    render json: { error_message: e.message }, status: :internal_server_error
  end

  def edit
    @path = PosixFile.new(normalized_path)
    @file_api_url = OodAppkit.files.api(path: @path).to_s

    if @path.editable?
      @content = @path.read
      render :edit, status: status, layout: 'editor'
    else
      redirect_to root_path, alert: "#{@path} is not an editable file"
    end
  end

  private

  def normalized_path
    Pathname.new("/" + params[:filepath].chomp("/").delete_prefix("/"))
  end

  def parse_path
    match = params[:filepath].match(/^(?<remote>[0-9A-Za-z_\.\- ]+:(\/)?)?(?<path>.*)$/)
    return PosixFile.new(normalized_path) if match[:remote].nil?
    remote = match[:remote].chomp("/").chomp(":")
    path = Pathname.new("/" + match[:path].chomp("/"))
    return RemoteFile.new(path, remote)
  end

  def validate_path!
    if posix_file?
      AllowlistPolicy.default.validate!(@path)
    elsif @path.remote_type.nil?
      raise StandardError, "Remote #{@path.remote} does not exist"
    elsif ::Configuration.allowlist_paths.present? && (@path.remote_type == "local" || @path.remote_type == "alias")
      # local and alias remotes would allow bypassing the AllowListPolicy
      # TODO: Attempt to evaluate the path of them and validate?
      raise StandardError, "Remotes of type #{@path.remote_type} are not allowed due to ALLOWLIST_PATH"
    end
  end

  def posix_file?
    @path.is_a?(PosixFile)
  end

  def uppy_upload_path
    # careful:
    #
    #     File.join '/a/b', '/c' => '/a/b/c'
    #     Pathname.new('/a/b').join('/c') => '/c'
    #
    # handle case where uppy.js sets relativePath to "null"
    if params[:relativePath] && params[:relativePath] != "null"
      Pathname.new(File.join(params[:parent], params[:relativePath]))
    else
      Pathname.new(File.join(params[:parent], params[:name]))
    end
  end

  def show_file
    if posix_file?
      send_posix_file
    else
      send_remote_file
    end
  end

  def send_posix_file
    type = Files.mime_type_by_extension(@path).presence || PosixFile.new(@path).mime_type

    # svgs aren't safe to view until we update our CSP
    if params[:download] || type.to_s == 'image/svg+xml'
      type = 'text/plain; charset=utf-8' if type.to_s == 'image/svg+xml'
      send_file @path, type: type
    else
      send_file @path, disposition: 'inline', type: Files.mime_type_for_preview(type)
    end
  rescue => e
    logger.warn("failed to determine mime type for file: #{@path} due to error #{e.message}")

    if params[:downlaod]
      send_file @path
    else
      send_file @path, disposition: 'inline'
    end
  end

  def send_remote_file
    type = Files.mime_type_by_extension(@path).presence || mime_type
    # svgs aren't safe to view until we update our CSP
    if params[:download] || type.to_s == "image/svg+xml"
      type = "text/plain; charset=utf-8" if type.to_s == "image/svg+xml"
      send_data @path.read, type: type
    else
      send_data @path.read, :disposition => "inline", :type => Files.mime_type_for_preview(type)
    end
  rescue => e
    logger.warn("failed to determine mime type for file: #{@path} due to error #{e}")

    if params[:download]
      send_data @path.read
    else
      send_data @path.read, disposition: "inline"
    end
  end
end
