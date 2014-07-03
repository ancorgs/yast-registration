# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2014 Novell, Inc. All Rights Reserved.
#
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
#

require "yast"

require "tmpdir"
require "fileutils"

require "registration/exceptions"
require "registration/helpers"
require "registration/control_file"

module Registration
  Yast.import "Mode"
  Yast.import "Pkg"
  Yast.import "PackageLock"
  Yast.import "Installation"
  Yast.import "PackageCallbacks"
  Yast.import "PackagesProposal"

  class SwMgmt
    include Yast
    include Yast::Logger
    extend Yast::I18n

    textdomain "registration"

    ZYPP_DIR = "/etc/zypp"

    def self.init
      # false = do not allow continuing without the libzypp lock
      lock = PackageLock.Connect(false)
      return false unless lock["connected"]

      # display progress when refreshing repositories
      PackageCallbacks.InitPackageCallbacks
      Pkg.TargetInitialize(Installation.destdir)
      Pkg.TargetLoad
      Pkg.SourceRestore
    end

    # during installation /etc/zypp directory is not writable (mounted on
    # a read-only file system), the workaround is to copy the whole directory
    # structure into a writable temporary directory and override the original
    # location by "mount -o bind"
    def self.zypp_config_writable!
      return if !(Mode.installation || Mode.update) || File.writable?(ZYPP_DIR)

      log.info "Copying libzypp config to a writable place"

      # create writable zypp directory structure in /tmp
      tmpdir = Dir.mktmpdir

      log.info "Copying #{ZYPP_DIR} to #{tmpdir} ..."
      ::FileUtils.cp_r ZYPP_DIR, tmpdir

      log.info "Mounting #{tmpdir} to #{ZYPP_DIR}"
      `mount -o bind #{tmpdir}/zypp #{ZYPP_DIR}`
    end

    def self.find_base_product
      # during installation the products are :selected,
      # on a running system the products are :installed
      # during upgrade use the newer selected product (same as in installation)
      products = Pkg.ResolvableProperties("", :product, "").find_all do |p|
        if Mode.normal
          # in installed system the base product has valid type
          p["status"] == :installed && p["type"] == "base"
        else
          # however during installation it's not set yet
          # but the base product comes from the first repository
          p["source"] == 0
        end
      end

      log.debug "Found base products: #{products}"
      log.info "Found base products: #{products.map{|p| p["name"]}}"
      log.warn "More than one base product found!" if products.size > 1

      products.first
    end

    # create UI label for a base product
    # @param [Hash] Product (hash from pkg-bindings)
    # @return [String] UI Label
    def self.base_product_label(base_product)
      base_product["display_name"] ||
        base_product["short_name"] ||
        base_product["name"] ||
        _("Unknown product")
    end

    def self.base_product_to_register
      # just for debugging:
      # return {"name" => "SLES", "arch" => "x86_64", "version" => "12",
      #   "release_type" => "DVD"
      # }

      base_product = find_base_product

      # filter out not needed data
      product_info = {
        "name"         => base_product["name"],
        "arch"         => base_product["arch"],
        "version"      => ::Registration::Helpers.base_version(base_product["version"]),
        "release_type" => base_product["flavor"]
      }

      log.info("Base product to register: #{product_info}")

      product_info
    end

    # add the services to libzypp and load (refresh) them
    def self.add_service(product_service, credentials)
      # save repositories before refreshing added services (otherwise
      # pkg-bindings will treat them as removed by the service refresh and
      # unload them)
      if !Pkg.SourceSaveAll
        # error message
        raise ::Registration::PkgError, N_("Saving repository configuration failed.")
      end

      # services for registered products
      log.info "Adding service #{product_service.name.inspect} (#{product_service.url})"

      credentials_file = Helpers.credentials_from_url(product_service.url)

      if credentials_file
        if Mode.update
          # at update libzypp is already switched to /mnt target,
          # update the path accordingly
          credentials_file = File.join(Installation.destdir,
            ::SUSE::Connect::Credentials::DEFAULT_CREDENTIALS_DIR,
            credentials_file)
          log.info "Using #{credentials_file} credentials path in update mode"
        end
        # TODO FIXME: SCC currenly does not return credentials for the service,
        # just reuse the global credentials and save to a different file
        service_credentials = credentials.dup
        service_credentials.file = credentials_file
        service_credentials.write
      end

      service_name = product_service.name

      # add a new service or update the existing service
      if Pkg.ServiceAliases.include?(service_name)
        log.info "Updating existing service: #{service_name}"
        if !Pkg.ServiceSet(service_name, {
              "alias" => service_name,
              "name" => service_name,
              "url" => product_service.url.to_s,
              "enabled" => true,
              "autorefresh" => true,
            })

          ## error message
          raise ::Registration::ServiceError.new(N_("Updating service '%s' failed."), service_name)
        end
      else
        log.info "Adding new service: #{service_name}"
        if !Pkg.ServiceAdd(service_name, product_service.url.to_s)
          # error message
          raise ::Registration::ServiceError.new(N_("Adding service '%s' failed."), service_name)
        end

        if !Pkg.ServiceSet(service_name, "autorefresh" => true)
          # error message
          raise ::Registration::ServiceError.new(N_("Updating service '%s' failed."), service_name)
        end
      end

      # refresh works only for saved services
      if !Pkg.ServiceSave(service_name)
        # error message
        raise ::Registration::ServiceError.new(N_("Saving service '%s' failed."), service_name)
      end

      if !Pkg.ServiceRefresh(service_name)
        # error message
        raise ::Registration::ServiceError.new(N_("Refreshing service '%s' failed."), service_name)
      end
    ensure
      Pkg.SourceSaveAll
    end

    # get list of repositories belonging to registered services
    # @param product_services [SUSE::Connect::Remote::Service] added service
    # @param only_updates [Boolean] return only update repositories
    # @return [Array<Hash>] list of repositories
    def self.service_repos(product_service, only_updates: false)
      repo_data = Pkg.SourceGetCurrent(false).map do |repo|
        data = Pkg.SourceGeneralData(repo)
        data["SrcId"] = repo
        data
      end

      service_name = product_service.name
      log.info "Added service: #{service_name.inspect}"

      # select only repositories belonging to the product services
      repos = repo_data.select{|repo| service_name == repo["service"]}
      log.info "Service repositories: #{repos}"

      if only_updates
        # leave only update repositories
        repos.select!{|repo| repo["is_update_repo"]}
        log.info "Found update repositories: #{repos}"
      end

      repos
    end

    # Set repository state (enabled/disabled)
    # @param repos [Array<Hash>] list of repositories
    # @param repos [Boolean] true = enable, false = disable, nil = no change
    # @return [void]
    def self.set_repos_state(repos, enabled)
      # keep the defaults when not defined
      return if enabled.nil?

      repos.each do |repo|
        if repo["enabled"] != enabled
          log.info "Changing repository state: #{repo["name"]} enabled: #{enabled}"
          Pkg.SourceSetEnabled(repo["SrcId"], enabled)
        end
      end
    end

    # copy old NCC/SCC credentials from the old installation to new SCC credentials
    # the files are copied to the current system
    def self.copy_old_credentials(source_dir)
      log.info "Searching registration credentials in #{source_dir}..."

      # check for NCC credentials
      dir = SUSE::Connect::Credentials::DEFAULT_CREDENTIALS_DIR
      ncc_file = File.join(source_dir, dir, "NCCcredentials")
      scc_file = File.join(source_dir, SUSE::Connect::Credentials::GLOBAL_CREDENTIALS_FILE)
      new_file = SUSE::Connect::Credentials::GLOBAL_CREDENTIALS_FILE

      # ensure the zypp directory is writable in inst-sys
      zypp_config_writable!

      # create the target directory if missing
      if !File.exist?(dir)
        log.info "Creating directory #{dir}"
        ::FileUtils.mkdir_p(dir)
      end

      if File.exist?(ncc_file)
        log.info "Copying the old NCC credentials from previous installation"
        log.info "Copying #{ncc_file} to #{new_file}"
        ::FileUtils.cp(ncc_file, new_file)
      end

      if File.exist?(scc_file)
        log.info "Copying the old SCC credentials from previous installation"
        log.info "Copying #{scc_file} to #{new_file}"
        ::FileUtils.cp(scc_file, new_file)
      end
    end

    def self.find_addon_updates(addons)
      products = Pkg.ResolvableProperties("", :product, "")

      installed_addons = products.select do |product|
        product["status"] == :installed && product["type"] != "base"
      end

      ret = addons.select do |addon|
        installed_addons.any? do |installed_addon|
          addon.updates_addon?(installed_addon)
        end
      end

      log.info "Found addons to update: #{ret}"
      ret
    end
    
    def self.preselect_patterns(control_file)
      control = ::Registration::ControlFile.new(control_file)
      
      default_patterns = control.default_patterns
      if !default_patterns.empty?
        PackagesProposal.AddResolvables("y2_registration_patterns", :pattern,
          default_patterns)
      end

      default_optional_patterns = control.default_optional_patterns
      if !default_optional_patterns.empty?
        
        # find available pattern names
        available_patterns = Pkg.ResolvableProperties("", :pattern, "").
          select { |pattern| pattern["status"] == :available}.
          map { |pattern| pattern["name"] }.
          uniq!

        # filter out not available patterns
        default_optional_patterns.reject! { |pattern| available_patterns.include?(pattern) }
        
        if !default_optional_patterns.empty?
          PackagesProposal.AddResolvables("y2_registration_optional_patterns",
            :pattern, default_optional_patterns)
        end
      end
      
    end

    # a helper method for iterating over repositories
    # @param repo_aliases [Array<String>] list of repository aliases
    # @param block block evaluated for each found repository
    def self.each_repo(repo_aliases, &block)
      all_repos = Pkg.SourceGetCurrent(false)

      repo_aliases.each do |repo_alias|
        # find the repository with the alias
        repo = all_repos.find do |repo|
          Pkg.SourceGeneralData(repo)["alias"] == repo_alias
        end

        if repo
          yield(repo)
        else
          log.warn "Repository '#{repo_alias}' was not found, skipping"
        end
      end
    end
    
    private_class_method :each_repo
  end
end

