# encoding: utf-8

require "instagram"

module CartoDB
  module Datasources
    module Url
      class InstagramOAuth < BaseOAuth

        # Required for all datasources
        DATASOURCE_NAME = 'instagram'

        # Constructor
        # @param config Array
        # [
        #  'app_key'
        #  'app_secret'
        #  'callback_url'
        # ]
        # @param user User
        # @throws UninitializedError
        # @throws MissingConfigurationError
        def initialize(config, user)
          super

          raise UninitializedError.new('missing user instance', DATASOURCE_NAME)        if user.nil?
          raise MissingConfigurationError.new('missing app_key', DATASOURCE_NAME)       unless config.include?('app_key')
          raise MissingConfigurationError.new('missing app_secret', DATASOURCE_NAME)    unless config.include?('app_secret')
          raise MissingConfigurationError.new('missing callback_url', DATASOURCE_NAME)  unless config.include?('callback_url')

          @user               = user
          @app_key            = config.fetch('app_key')
          @app_secret         = config.fetch('app_secret')
          @callback_url       = config.fetch('callback_url')

          self.filter   = []
          @access_token = nil
          @auth_flow    = nil
          @client       = nil
        end

        # Factory method
        # @param config : {}
        # @param user : User
        # @return CartoDB::Datasources::Url::InstagramOAuth
        def self.get_new(config, user)
          return new(config, user)
        end

        # If will provide a url to download the resource, or requires calling get_resource()
        # @return bool
        def providers_download_url?
          false
        end

        # Return the url to be displayed or sent the user to to authenticate and get authorization code
        # @param use_callback_flow : bool
        # @throws AuthError
        def get_auth_url(use_callback_flow=true)
          # TODO: Add CSRF here (http://instagram.com/developer/authentication/)
          Instagram.authorize_url({
            client_id:      @app_key,
            response_type:  'code',
            redirect_uri:   @callback_url
          })
        rescue => ex
          raise AuthError.new("get_auth_url(#{use_callback_flow}): #{ex.message}", DATASOURCE_NAME)
        end

        # Validates the authorization callback
        # @param params : mixed
        def validate_callback(params)
          response = Instagram.get_access_token(params[:code], {
            client_id:      @app_key,
            client_secret:  @app_secret,
            redirect_uri:   @callback_url
          })
          @access_token = response.access_token
          @client = Instagram.client(access_token: @access_token)
          @access_token
        rescue => ex
          raise AuthError.new("validate_callback(#{params.inspect}): #{ex.message}", DATASOURCE_NAME)
        end

        # Set the token
        # @param token string
        # @throws TokenExpiredOrInvalidError
        # @throws AuthError
        def token=(token)
          @access_token = token
          @client = Instagram.client(access_token: @access_token)
        rescue => ex
          handle_error(ex, "token= : #{ex.message}")
        end

        # Retrieve set token
        # @return string | nil
        def token
          @access_token
        end

        # Perform the listing and return results
        # @param filter Array : (Optional) filter to specify which resources to retrieve. Leave empty for all supported.
        # @return [ { :id, :title, :url, :service } ]
        # @throws TokenExpiredOrInvalidError
        # @throws AuthError
        # @throws DataDownloadError
        def get_resources_list(filter=[])
          [
            {
              id:      'all_media',
              title:    'All your photos and videos',
              url:      'All your photos and videos',
              service:  DATASOURCE_NAME
            }
          ]
        end

        # Retrieves a resource and returns its contents
        # @param id string
        # @return mixed
        # @throws TokenExpiredOrInvalidError
        # @throws AuthError
        # @throws DataDownloadError
        def get_resource(id)
          contents,  = @client.get_file_and_metadata(id)
          contents
        rescue => ex
          handle_error(ex, "get_resource() #{id}: #{ex.message}")
        end

        # @param id string
        # @return Hash
        # @throws TokenExpiredOrInvalidError
        # @throws AuthError
        # @throws DataDownloadError
        def get_resource_metadata(id)
          response = @client.metadata(id)
          item_data = format_item_data(response)

          item_data.to_hash
        rescue => ex
          handle_error(ex, "get_resource_metadata() #{id}: #{ex.message}")
        end

        # Retrieves current filters
        # @return {}
        def filter
          @formats
        end

        # Sets current filters
        # @param filter_data {}
        def filter=(filter_data=[])
          nil
        end

        # Just return datasource name
        # @return string
        def to_s
          DATASOURCE_NAME
        end

        # If this datasource accepts a data import instance
        # @return Boolean
        def persists_state_via_data_import?
          false
        end

        # Stores the data import item instance to use/manipulate it
        # @param value DataImport
        def data_import_item=(value)
          nil
        end

        # Checks if token is still valid or has been revoked
        # @return bool
        # @throws AuthError
        def token_valid?
          # TODO: See how to check this
          true
        end

        # Revokes current set token
        def revoke_token
          # TODO: See how to check this
          true
        rescue => ex
          raise AuthError.new("revoke_token: #{ex.message}", DATASOURCE_NAME)
        end

        # Sets an error reporting component
        # @param component mixed
        def report_component=(component)
          nil
        end

        private

        # Handles
        # @param original_exception mixed
        # @param message string
        # @throws TokenExpiredOrInvalidError
        # @throws AuthError
        # @throws mixed
        def handle_error(original_exception, message)
          # TODO: Implement
          raise original_exception
        end

        # Formats all data to comply with our desired format
        # @param item_data Hash : Single item returned from Dropbox API
        # @return { :id, :title, :url, :service, :size }
        def format_item_data(item_data)
          filename = item_data.fetch('path').split('/').last

          {
            id:       item_data.fetch('path'),
            title:    filename,
            filename: filename,
            service:  DATASOURCE_NAME,
            checksum: checksum_of(item_data.fetch('rev')),
            size:     item_data.fetch('bytes').to_i
          }
        end

        # Calculates a checksum of given input
        # @param origin string
        # @return string
        def checksum_of(origin)
          #noinspection RubyArgCount
          Zlib::crc32(origin).to_s
        end

      end
    end
  end
end
