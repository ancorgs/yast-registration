# encoding: utf-8

# ------------------------------------------------------------------------------
# Copyright (c) 2013 Novell, Inc. All Rights Reserved.
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
# Summary: Ask user for the SCC credentials
#

# use external rubygem for SCC communication
require "yast/suse_connect"

require "cgi"

require "registration/addon"
require "registration/exceptions"
require "registration/helpers"
require "registration/connect_helpers"
require "registration/sw_mgmt"
require "registration/storage"
require "registration/url_helpers"
require "registration/registration"
require "registration/ui/addon_eula_dialog"
require "registration/ui/addon_selection_dialog"
require "registration/ui/addon_reg_codes_dialog"
require "registration/ui/local_server_dialog"

module Yast
  class InstSccClient < Client
    include Yast::Logger
    extend Yast::I18n

    # width of reg code input field widget
    REG_CODE_WIDTH = 33

    # popup message
    CONTACTING_MESSAGE = N_("Contacting the Registration Server")

    def main
      Yast.import "UI"

      textdomain "registration"

      Yast.import "Popup"
      Yast.import "GetInstArgs"
      Yast.import "Wizard"
      Yast.import "Report"
      Yast.import "Mode"
      Yast.import "Stage"
      Yast.import "Label"
      Yast.import "Sequencer"
      Yast.import "Installation"
      Yast.import "ProductControl"
      Yast.import "SourceDialogs"

      first_run

      @selected_addons = ::Registration::Storage::InstallationOptions.instance.selected_addons

      initialize_regcodes

      start_workflow
    end

    private

    # initialize known reg. codes
    def initialize_regcodes
      @known_reg_codes = ::Registration::Storage::RegCodes.instance.reg_codes
      if @known_reg_codes
        log.info "Known reg codes: #{@known_reg_codes.size} codes"
        return
      end

      @known_reg_codes = {}

      # cache the values
      ::Registration::Storage::RegCodes.instance.reg_codes = @known_reg_codes
    end

    def register_base_system
      show_scc_credentials_dialog

      ret = nil
      @registration_skipped = false

      continue_buttons = [:next, :back, :cancel, :abort]
      while !continue_buttons.include?(ret) do
        ret = UI.UserInput

        case ret
        when :network
          ::Registration::Helpers::run_network_configuration
        when :local_server
          options = ::Registration::Storage::InstallationOptions.instance
          current_url = options.custom_url || SUSE::Connect::Config.new.url
          url = ::Registration::UI::LocalServerDialog.run(current_url)
          if url
            log.info "Entered custom URL: #{url}"
            options.custom_url = url
          end
        when :next
          options = ::Registration::Storage::InstallationOptions.instance

          # do not re-register during installation
          if !Mode.normal && ::Registration::Registration.is_registered? &&
              options.base_registered

            return :next
          end

          email = UI.QueryWidget(:email, :Value)
          reg_code = UI.QueryWidget(:reg_code, :Value)

          # remember the entered values in case user goes back
          options.email = email
          options.reg_code = reg_code

          # reset the user input in case an exception is raised
          ret = nil

          next if init_registration == :cancel

          success = ::Registration::ConnectHelpers.catch_registration_errors do
            base_product = ::Registration::SwMgmt.find_base_product
            distro_target = base_product["register_target"]

            if !::Registration::Registration.is_registered?
              log.info "Registering system, distro_target: #{distro_target}"

              Popup.Feedback(_(CONTACTING_MESSAGE),
                _("Registering the System...")) do

                @registration.register(email, reg_code, distro_target)
              end
            end

            if !options.base_registered
              # then register the product(s)
              product_service = Popup.Feedback(_(CONTACTING_MESSAGE),
                _("Registering %s ...") % ::Registration::SwMgmt.base_product_label(base_product)
              ) do

                base_product_data = ::Registration::SwMgmt.base_product_to_register
                base_product_data["reg_code"] = reg_code
                registered_service = @registration.register_product(base_product_data, email)
                options.base_registered = true

                registered_service
              end

              # select repositories to use in installation or update (e.g. enable/disable Updates)
              select_repositories(product_service) if Mode.installation || Mode.update
            end

            return :next
          end

          if success
            # save the config if running in installed system
            # (in installation/upgrade it's written in _finish client)
            ::Registration::Helpers.write_config if Mode.normal
          else
            log.info "registration failed, resetting the registration URL"
            # reset the registration object and the cache to allow changing the URL
            @registration = nil
            ::Registration::UrlHelpers::reset_registration_url
            ::Registration::Helpers.reset_registration_status
          end
        when :abort
          ret = nil unless Popup.ConfirmAbort(:painless)
        end

        if ret == :skip && confirm_skipping
          log.info "Skipping registration on user request"
          @registration_skipped = true
          return ret
        end
      end

      return ret
    end

    def refresh_base_product
      init_registration

      upgraded = ::Registration::ConnectHelpers.catch_registration_errors(show_update_hint: true) do
        # then register the product(s)
        base_product = ::Registration::SwMgmt.base_product_to_register
        product_services = Popup.Feedback(
          _(CONTACTING_MESSAGE),
          # updating base product registration, %s is a new base product name
          _("Updating to %s ...") % ::Registration::SwMgmt.base_product_label(
            ::Registration::SwMgmt.find_base_product)
        ) do
          @registration.upgrade_product(base_product)
        end

        # select repositories to use in installation (e.g. enable/disable Updates)
        select_repositories(product_services)
      end

      if !upgraded
        log.info "Registration upgrade failed, removing the credentials to register from scratch"
        ::Registration::Helpers.reset_registration_status
      end

      upgraded
    end

    def refresh_addons
      addons = get_available_addons

      # find addon updates
      addons_to_update = ::Registration::SwMgmt.find_addon_updates(addons)

      failed_addons = addons_to_update.reject do |addon_to_update|
        ::Registration::ConnectHelpers.catch_registration_errors do
          # then register the product(s)
          product_services = Popup.Feedback(
            _(CONTACTING_MESSAGE),
            # updating registered addon/extension, %s is an extension name
            _("Updating to %s ...") % addon_to_update.label
          ) do
            @registration.upgrade_product(addon_to_update)
          end

          # mark as registered
          addon_to_update.registered

          select_repositories(product_services)
        end
      end

      if !failed_addons.empty?
        log.warn "Failed addons: #{failed_addons}"
        # if update fails preselest the addon for full registration
        failed_addons.each(&:selected)
      end

      :next
    end

    # display the registration update dialog
    def show_registration_update_dialog
      Wizard.SetContents(
        _("Registration"),
        Label(_("Registration is being updated...")),
        _("The previous registration is being updated."),
        GetInstArgs.enable_back,
        GetInstArgs.enable_next || Mode.normal
      )
    end

    def update_registration
      show_registration_update_dialog

      if refresh_base_product
        return refresh_addons
      else
        # automatic registration refresh during system upgrade failed, register from scratch
        Report.Error(_("Automatic registration upgrade failed.\n" +
              "You can manually register the system from scratch."))
        return :register
      end
    end

    # content for the main registration dialog
    def scc_credentials_dialog
      base_product = ::Registration::SwMgmt.find_base_product

      options = ::Registration::Storage::InstallationOptions.instance

      # label text describing the registration (1/2)
      # use \n to split to more lines if needed (use max. 76 chars/line)
      info = _("Please enter a registration or evaluation code for this product and your\n" +
          "User Name/E-mail address from the SUSE Customer Center in the fields below.\n" +
          "Access to security and general software updates is only possible on\n" +
          "a registered system.")

      if !Mode.normal
        # add a paragraph separator
        info += "\n\n"

        # label text describing the registration (2/2),
        # not displayed in installed system
        # use \n to split to more lines if needed (use max. 76 chars/line)
        info += _("If you skip product registration now, remember to register after\n" \
            "installation has completed.")
      end

      registered = ::Registration::Registration.is_registered?

      VBox(
        Mode.installation || Mode.update ?
          Right(PushButton(Id(:network), _("Network Configuration..."))) :
          Empty(),
        VStretch(),
        HSquash(
          VBox(
            VSpacing(1),
            Left(Heading(::Registration::SwMgmt.base_product_label(base_product))),
            VSpacing(1),
            registered ?
              Heading(_("The system is already registered.")) :
              Label(info)
          )
        ),
        VSpacing(UI.TextMode ? 1 : 2),
        HSquash(
          VBox(
            MinWidth(REG_CODE_WIDTH, InputField(Id(:email), _("&E-mail Address"), options.email)),
            VSpacing(UI.TextMode ? 0 : 0.5),
            MinWidth(REG_CODE_WIDTH, InputField(Id(:reg_code), _("Registration &Code"), options.reg_code))
          )
        ),
        VSpacing(UI.TextMode ? 0 : 1),
        # button label
        PushButton(Id(:local_server), _("&Local Registration Server...")),
        VSpacing(UI.TextMode ? 0 : 3),
        # button label
        registered ? Empty() : PushButton(Id(:skip), _("&Skip Registration")),
        VStretch()
      )
    end

    # help text for the main registration dialog
    def scc_help_text
      # help text
      _("Enter SUSE Customer Center credentials here to register the system to " \
          "get updates and extensions.")
    end

    # display the main registration dialog
    def show_scc_credentials_dialog

      Wizard.SetContents(
        # dialog title
        _("Registration"),
        scc_credentials_dialog,
        scc_help_text,
        GetInstArgs.enable_back,
        GetInstArgs.enable_next || Mode.normal
      )

      registered = ::Registration::Registration.is_registered?
      # disable the input fields when already registered
      if registered && !Mode.normal
        UI.ChangeWidget(Id(:email), :Enabled, false)
        UI.ChangeWidget(Id(:reg_code), :Enabled, false)
      end
    end

    def select_repositories(product_service)
      options = ::Registration::Storage::InstallationOptions.instance

      # added update repositories
      updates = ::Registration::SwMgmt.service_repos(product_service, only_updates: true)
      log.info "Found update repositories: #{updates.size}"

      # not set yet?
      if options.install_updates.nil?
        options.install_updates = Popup.YesNo(
          _("Registration added some update repositories.\n\n" +
              "Do you want to install the latest available\n" +
              "on-line updates during installation?"))
      end

      ::Registration::SwMgmt.set_repos_state(updates, options.install_updates)
    end

    # run the addon selection dialog
    def select_addons
      return :back
      get_available_addons # FIXME just to fill cache with popup

      # FIXME workaround to reference between old way and new storage in Addon metaclass
      @selected_addons = Registration::Addon.selected
      ::Registration::Storage::InstallationOptions.instance.selected_addons = @selected_addons

      Registration::UI::AddonSelectionDialog.run(@registration)
    end


    # load available addons from SCC server
    # the result is cached to avoid reloading when going back and forth in the
    # installation workflow
    def get_available_addons
      # cache the available addons
      init_registration

      @available_addons = Popup.Feedback(
        _(CONTACTING_MESSAGE),
        _("Loading Available Extensions and Modules...")) do

        Registration::Addon.find_all(@registration)
      end

      ::Registration::Storage::Cache.instance.available_addons = @available_addons
      @available_addons
    end

    # register all selected addons
    def register_selected_addons
      # create duplicate as array is modified in loop for registration order
      registration_order = @selected_addons.clone

      init_registration

      product_succeed = registration_order.map do |product|
        ::Registration::ConnectHelpers.catch_registration_errors(message_prefix: "#{product.label}\n") do
          product_service = Popup.Feedback(
            _(CONTACTING_MESSAGE),
            # %s is name of given product
            _("Registering %s ...") % product.label) do

            product_data = {
              "name" => product.identifier,
              "reg_code" => @known_reg_codes[product.identifier],
              "arch" => product.arch,
              "version" => product.version
            }

            @registration.register_product(product_data)
          end

          # select repositories to use in installation (e.g. enable/disable Updates)
          select_repositories(product_service) if Mode.installation || Mode.update

          # remember the added service
          ::Registration::Storage::Cache.instance.addon_services << product_service

          # move from selected to registered
          product.registered
          @selected_addons.reject!{|selected| selected.identifier == product.identifier}
        end
      end

      return !product_succeed.include?(false) # succeed only if noone failed
    end

    # run the addon reg codes dialog
    def register_addons
      # if registering only add-ons which do not need a reg. code (like SDK)
      # then simply start the registration
      if @selected_addons.all?(&:free)
        Wizard.SetContents(
          # dialog title
          _("Register Extensions and Modules"),
          # display only the products which need a registration code
          Empty(),
          # help text
          _("<p>Extensions and Modules are being registered.</p>"),
          false,
          false
        )
        # when registration fails go back
        return register_selected_addons ? :next : :back
      else
        loop do
          ret = ::Registration::UI::AddonRegCodesDialog.run(@selected_addons, @known_reg_codes)
          return ret unless ret == :next

          return :next if register_selected_addons
        end
      end
    end

    def confirm_skipping
      # Popup question: confirm skipping the registration
      confirmation = _("If you do not register your system we will not be able\n" +
          "to grant you access to the update repositories.\n\n" +
          "You can register after the installation or visit our\n" +
          "Customer Center for online registration.\n\n" +
          "Really skip the registration now?")

      Popup.YesNo(confirmation)
    end

    def registered_dialog
      VBox(
        Heading(_("The system is already registered.")),
        VSpacing(2),
        # button label
        PushButton(Id(:register), _("Register Again")),
        VSpacing(1),
        # button label
        PushButton(Id(:extensions), _("Select Extensions"))
      )
    end

    def display_registered_dialog
      Wizard.SetContents(
        # dialog title
        _("Registration"),
        registered_dialog,
        # help text
        _("<p>The system is already registered.</p>") +
          _("<p>You can re-register it again or you can register additional "\
            "extension or modules to enhance the functionality of the system.</p>") +
          _("<p>If you want to deregister your system you need to log "\
            "into the SUSE Customer Center and remove the system manually there.</p>"),
        GetInstArgs.enable_back || Mode.normal,
        GetInstArgs.enable_back || Mode.normal
      )

      Wizard.SetNextButton(:next, Label.FinishButton) if Mode.normal

      continue_buttons = [:next, :back, :cancel, :abort, :register, :extensions]

      ret = nil
      while !continue_buttons.include?(ret) do
        ret = UI.UserInput
      end

      Wizard.RestoreNextButton

      return ret
    end

    def registration_check
      # check the base product at start to avoid problems later
      if ::Registration::SwMgmt.find_base_product.nil?
        # error message
        msg = _("The base product was not found,\ncheck your system.") + "\n\n"

        if Stage.initial
          # TRANSLATORS: %s = bugzilla URL
          msg += _("The installation medium or the installer itself is seriously broken.\n" \
              "Report a bug at %s.") % "https://bugzilla.novell.com"
        else
          msg += _("Make sure a product is installed and /etc/products.d/baseproduct\n" \
              "is a symlink pointing to the base product .prod file.")
        end

        Report.Error(msg)

        return Mode.normal ? :abort : :auto
      end

      if Mode.update
        Wizard.SetContents(
          _("Registration"),
          Empty(),
          # no help text needed, the dialog displays just a progress message
          "",
          false,
          false
        )

        ::Registration::SwMgmt.copy_old_credentials(Installation.destdir)

        if File.exists?(::Registration::Registration::SCC_CREDENTIALS)
          # update the registration using the old credentials
          return :update
        end
      end

      if Mode.normal && ::Registration::Registration.is_registered?
        return display_registered_dialog
      else
        return :register
      end
    end

    def addon_eula
      ::Registration::UI::AddonEulaDialog.run(@selected_addons)
    end

    def update_autoyast_config
      options = ::Registration::Storage::InstallationOptions.instance
      return :next unless Mode.installation && options.base_registered

      log.info "Updating Autoyast config"
      config = ::Registration::Storage::Config.instance
      config.import(::Registration::Helpers.collect_autoyast_config(@known_reg_codes))
      config.modified = true
      :next
    end

    def pkg_manager
      # during installation the products are installed together with the base
      # product, run the package manager only in installed system
      return :next unless Mode.normal

      ::Registration::SwMgmt.select_addon_products

      WFM.call("sw_single")
    end

    # UI workflow definition
    def start_workflow
      aliases = {
        # skip this when going back
        "check"           => [ lambda { registration_check() }, true ],
        "register"        => lambda { register_base_system() },
        "select_addons"   => lambda { select_addons() },
        "update"          => [ lambda { update_registration() }, true ],
        "addon_eula"      => lambda { addon_eula() },
        "register_addons" => lambda { register_addons() },
        "update_autoyast_config" => lambda { update_autoyast_config() },
        "pkg_manager" => lambda { pkg_manager() }
      }

      sequence = {
        "ws_start" => workflow_start,
        "check" => {
          :auto       => :auto,
          :abort      => :abort,
          :cancel     => :abort,
          :register   => "register",
          :extensions => "select_addons",
          :update     => "update",
          :next       => :next
        },
        "update" => {
          :abort   => :abort,
          :cancel   => :abort,
          :next => "select_addons",
          :register => "register",
        },
        "register" => {
          :abort    => :abort,
          :cancel   => :abort,
          :skip     => :next,
          :next     => "select_addons"
        },
        "select_addons" => {
          :abort    => :abort,
          :skip     => :next,
          :back     => "check",
          :next     => "addon_eula"
        },
        "addon_eula" => {
          :abort    => :abort,
          :next     => "register_addons"
        },
        "register_addons" => {
          :abort    => :abort,
          :next     => "update_autoyast_config"
        },
        "update_autoyast_config" => {
          :abort    => :abort,
          :next     => "pkg_manager"
        },
        "pkg_manager" => {
          :abort    => :abort,
          :next     => :next
        }
      }

      log.info "Starting scc sequence"
      Sequencer.Run(aliases, sequence)
    end

    # which dialog should be displayed at start
    def workflow_start
      log.debug "WFM.Args: #{WFM.Args}"
      WFM.Args.include?("select_extensions") && Registration::Registration.is_registered? ?
        "select_addons" : "check"
    end

    def init_registration
      if !@registration
        url = ::Registration::UrlHelpers.registration_url
        return :cancel if url == :cancel
        @registration = ::Registration::Registration.new(url)
      end
    end

    def first_run
      if ::Registration::Storage::Cache.instance.first_run
        ::Registration::Storage::Cache.instance.first_run = false

        if Stage.initial && ::Registration::Registration.is_registered?
          ::Registration::Helpers.reset_registration_status
        end
      end
    end

  end unless defined?(InstSccClient)
end

Yast::InstSccClient.new.main
