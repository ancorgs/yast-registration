# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2014 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of version 2 of the GNU General Public License as published by the
# Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, contact Novell, Inc.
#
# To contact Novell about this file by physical or electronic mail, you may find
# current contact information at www.novell.com.
# ------------------------------------------------------------------------------
#

require "yast"
require "suse/connect"

require "registration/addon"
require "registration/helpers"
require "registration/sw_mgmt"
require "registration/storage"
require "registration/ssl_certificate"

module Registration
  class Registration
    include Yast::Logger

    SCC_CREDENTIALS = SUSE::Connect::Credentials::GLOBAL_CREDENTIALS_FILE

    attr_accessor :url

    def initialize(url = nil)
      @url = url
    end

    def register(email, reg_code, distro_target)
      settings = connect_params(
        token: reg_code,
        email: email
      )

      login, password = SUSE::Connect::YaST.announce_system(settings, distro_target)
      credentials = SUSE::Connect::Credentials.new(login, password, SCC_CREDENTIALS)

      log.info "Global SCC credentials: #{credentials}"

      # ensure the zypp config directories are writable in inst-sys
      ::Registration::SwMgmt.zypp_config_writable!

      # write the global credentials
      credentials.write
    end

    def register_product(product, email = nil)
      service_for_product(product) do |product_ident, params|
        log_product = product.dup
        log_product["reg_code"] = "[FILTERED]" if log_product["reg_code"]
        log.info "Registering product: #{log_product}"

        service = SUSE::Connect::YaST.activate_product(product_ident, params, email)
        log.info "Register product result: #{service}"
        set_registered(product_ident)

        service
      end
    end

    def upgrade_product(product)
      service_for_product(product) do |product_ident, params|
        log.info "Upgrading product: #{product}"
        service = SUSE::Connect::YaST.upgrade_product(product_ident, params)
        log.info "Upgrade product result: #{service}"
        set_registered(product_ident)

        service
      end
    end

    # @param [String] target_distro new target distribution
    # @return [OpenStruct] SCC response
    def update_system(target_distro = nil)
      log.info "Updating the system, new target distribution: #{target_distro}"
      ret = SUSE::Connect::YaST.update_system(connect_params, target_distro)
      log.info "Update result: #{ret}"
      ret
    end

    def get_addon_list
      # extensions for base product
      base_product = ::Registration::SwMgmt.base_product_to_register

      log.info "Reading available addons for product: #{base_product["name"]}"

      remote_product = SUSE::Connect::Remote::Product.new(
        arch: base_product["arch"],
        identifier: base_product["name"],
        version: base_product["version"],
        release_type: base_product["release_type"]
      )

      params = connect_params
      addons = SUSE::Connect::YaST.show_product(remote_product, params).extensions || []
      log.info "Available addons result: #{addons}"

      renames = collect_renames(addons)
      ::Registration::SwMgmt.update_product_renames(renames)

      # ignore the base product "addon"
      addons.reject { |a| a.identifier == base_product["name"] }
    end

    def activated_products
      log.info "Reading activated products..."
      activated = SUSE::Connect::YaST.status(connect_params).activated_products || []
      log.info "Activated products: #{activated.map(&:id)}"
      activated
    end

    def self.is_registered?
      # just a simple file check without connection to SCC
      File.exist?(SCC_CREDENTIALS)
    end

    private

    def set_registered(remote_product)
      addon = Addon.find_all(self).find do |a|
        a.arch == remote_product.arch &&
        a.identifier == remote_product.identifier &&
        a.version  == remote_product.version &&
        a.release_type == remote_product.release_type
      end

      return unless addon

      log.info "Marking addon #{addon.identifier}-#{addon.version} as registered"
      addon.registered
    end

    def service_for_product(product, &_block)
      if product.is_a?(Hash)
        remote_product =  SUSE::Connect::Remote::Product.new(
          arch: product["arch"],
          identifier: product["name"],
          version: product["version"],
          release_type: product["release_type"]
        )
      else
        remote_product = product
      end

      log.info "Using product: #{remote_product}"

      params = connect_params

      # use product specific reg. code (e.g. for addons)
      if product.is_a?(Hash) && product["reg_code"]
        params[:token] = product["reg_code"]
      end

      product_service = yield(remote_product, params)

      log.info "registration result: #{product_service}"

      if product_service
        credentials = SUSE::Connect::Credentials.read(SCC_CREDENTIALS)
        ::Registration::SwMgmt.add_service(product_service, credentials)
      end

      product_service
    end

    # returns SSL verify callback
    def verify_callback
      lambda do |verify_ok, context|
        begin
          # we cannot raise an exception with details here (all exceptions in
          # verify_callback are caught and ignored), we need to store the error
          # details in a global instance
          store_ssl_error(context) unless verify_ok

          verify_ok
        rescue StandardError => e
          log.error "Exception in SSL verify callback: #{e.class}: #{e.message} : #{e.backtrace}"
          # the exception will be ignored, but reraise anyway...
          raise e
        end
      end
    end

    def store_ssl_error(context)
      log.error "SSL verification failed: #{context.error}: #{context.error_string}"
      Storage::SSLErrors.instance.ssl_error_code = context.error
      Storage::SSLErrors.instance.ssl_error_msg = context.error_string
      Storage::SSLErrors.instance.ssl_failed_cert =
        context.current_cert ? SslCertificate.load(context.current_cert) : nil
    end

    def connect_params(params = {})
      default_params = {
        language: ::Registration::Helpers.http_language,
        debug: ENV["SCCDEBUG"],
        verbose: ENV["Y2DEBUG"] == "1",
        # pass a verify_callback to get details about failed SSL verification
        verify_callback: verify_callback
      }

      if @url
        log.info "Using custom registration URL: #{@url.inspect}"
        default_params[:url] = @url
      end

      if Helpers.insecure_registration
        log.warn "SSL certificate check disabled via reg_ssl boot parameter"
        default_params[:insecure] = true
      end

      default_params.merge(params)
    end

    def collect_renames(addons)
      renames = {}

      addons.each do |addon|
        if addon.former_identifier && addon.identifier != addon.former_identifier
          renames[addon.former_identifier] = addon.identifier
        end
      end

      log.info "Collected product renames: #{renames}"

      renames
    end
  end
end
