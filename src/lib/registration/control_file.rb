
require "yast"

module Registration
  class ControlFile
    include Yast::Logger

    Yast.import "XML"

    # Read and parse a control file
    # @param [String] file path to a XML file
    def initialize(file)
      @control = parse_control_file(file)
    end

    def default_patterns
      value = control.fetch("software", {})["default_patterns"]
      value ? value.split : []
    end

    def default_optional_patterns
      value = control.fetch("software", {})["default_optional_patterns"]
      value ? value.split : []
    end

    private

    attr_accessor :control

    # Parse an installation.xml
    # @param [String] file input file name
    # @return [Hash] parsed file
    def self.parse_control_file(file)
      log.info "Parsing control file: #{file}"
      XML.XMLToYCPFile(file)
    end

  end
end
