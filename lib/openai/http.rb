module OpenAI
  module HTTP
    def get(path:)
      to_json(conn.get(uri(path: path)) do |req|
        req.headers = headers
      end&.body)
    end

    def json_post(path:, parameters:)
      to_json(conn.post(uri(path: path)) do |req|
        if parameters[:stream].respond_to?(:call)
          req.options.on_data = to_json_stream(user_proc: parameters[:stream])
          parameters[:stream] = true # Necessary to tell OpenAI to stream.
        elsif parameters[:stream]
          raise ArgumentError, "The stream parameter must be a Proc or have a #call method"
        end

        req.headers = headers
        req.body = parameters.to_json
      end&.body)
    end

    def multipart_post(path:, parameters: nil)
      to_json(conn(multipart: true).post(uri(path: path)) do |req|
        req.headers = headers.merge({ "Content-Type" => "multipart/form-data" })
        req.body = multipart_parameters(parameters)
      end&.body)
    end

    def delete(path:)
      to_json(conn.delete(uri(path: path)) do |req|
        req.headers = headers
      end&.body)
    end

    private

    def to_json(string)
      return unless string

      JSON.parse(string)
    rescue JSON::ParserError
      # Convert a multiline string of JSON objects to a JSON array.
      JSON.parse(string.gsub("}\n{", "},{").prepend("[").concat("]"))
    end

    # Given a proc, returns an outer proc that can be used to iterate over a JSON stream of chunks.
    # For each chunk, the inner user_proc is called giving it the JSON object. The JSON object could
    # be a data object or an error object as described in the OpenAI API documentation.
    #
    # If the JSON object for a given data or error message is invalid, it is ignored.
    #
    # @param user_proc [Proc] The inner proc to call for each JSON object in the chunk.
    # @return [Proc] An outer proc that iterates over a raw stream, converting it to JSON.
    def to_json_stream(user_proc:)
      proc do |chunk, _|
        @buffer ||= ""
        @buffer += chunk
        while (match = @buffer.match(/(?:data|error): (\{.*\})/i))
          data = match[1]
          @buffer = @buffer[match.end(0)..-1]  # Remove the processed data from the buffer
          begin
            user_proc.call(JSON.parse(data))
          rescue JSON::ParserError => e
            # Ignore invalid JSON.
          end
        end
      end
    end

    def conn(multipart: false)
      Faraday.new do |f|
        f.options[:timeout] = @request_timeout
        f.request(:multipart) if multipart
      end
    end

    def uri(path:)
      if azure?
        base = File.join(@uri_base, path)
        "#{base}?api-version=#{@api_version}"
      else
        File.join(@uri_base, @api_version, path)
      end
    end

    def headers
      if azure?
        azure_headers
      else
        openai_headers
      end.merge(@extra_headers || {})
    end

    def openai_headers
      {
        "Content-Type" => "application/json",
        "Authorization" => "Bearer #{@access_token}",
        "OpenAI-Organization" => @organization_id
      }
    end

    def azure_headers
      {
        "Content-Type" => "application/json",
        "api-key" => @access_token
      }
    end

    def multipart_parameters(parameters)
      parameters&.transform_values do |value|
        next value unless value.respond_to?(:close) # File or IO object.

        # Doesn't seem like OpenAI needs mime_type yet, so not worth
        # the library to figure this out. Hence the empty string
        # as the second argument.
        Faraday::UploadIO.new(value, "", value.path)
      end
    end
  end
end
