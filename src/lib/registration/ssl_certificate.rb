
require "openssl"
require "suse/connect"
require "registration/downloader"

module Registration

  # class handling SSL certificate
  class SslCertificate
    # adds download_file() method
    extend Downloader

    attr_reader :x509_cert

    def initialize(x509_cert)
      @x509_cert = x509_cert
    end

    def self.load_file(file)
      cert = OpenSSL::X509::Certificate.new(File.read(file))
      SslCertificate.new(cert)
    end

    def self.load(data)
      cert = OpenSSL::X509::Certificate.new(data)
      SslCertificate.new(cert)
    end

    def self.download(url, insecure: false)
      result = download_file(url, insecure: insecure)
      load(result)
    end

    def sha1_fingerprint
      ::SUSE::Connect::YaST.cert_sha1_fingerprint(x509_cert)
    end

    def sha256_fingerprint
      ::SUSE::Connect::YaST.cert_sha256_fingerprint(x509_cert)
    end

    # certificate serial number (in HEX format, e.g. AB:CD:42:FF...)
    def serial
      x509_cert.serial.to_s(16).scan(/../).join(":")
    end

    def issued_on
      x509_cert.not_before.localtime.strftime("%F")
    end

    def valid_yet?
      Time.now > x509_cert.not_before
    end

    def expires_on
      x509_cert.not_after.localtime.strftime("%F")
    end

    def expired?
      Time.now > x509_cert.not_after
    end

    def subject_name
      find_subject_attribute("CN")
    end

    def subject_organization
      find_subject_attribute("O")
    end

    def subject_organization_unit
      find_subject_attribute("OU")
    end

    def issuer_name
      find_issuer_attribute("CN")
    end

    def issuer_organization
      find_issuer_attribute("O")
    end

    def issuer_organization_unit
      find_issuer_attribute("OU")
    end

    # check whether SSL certificate matches the expected fingerprint
    def fingerprint_match?(fingerprint_type, fingerprint)
      case fingerprint_type.upcase
      when "SHA1"
        sha1_fingerprint.upcase == fingerprint.upcase
      when "SHA256"
        sha256_fingerprint.upcase == fingerprint.upcase
      else
        false
      end
    end

    def import_to_system
      ::SUSE::Connect::YaST.import_certificate(x509_cert)
    end

    private

    # @param x509_name [OpenSSL::X509::Name] name object
    # @param attribute [String] requested attribute name. e.g. "CN"
    # @return attribut value or nil if not defined
    def find_name_attribute(x509_name, attribute)
      # to_a returns an attribute list, e.g.:
      # [["CN", "linux", 19], ["emailAddress", "root@...", 22], ["O", "YaST", 19], ...]
      attr_list = x509_name.to_a.find(Array.method(:new)) { |a| a.first == attribute }
      attr_list[1]
    end

    def find_issuer_attribute(attribute)
      find_name_attribute(x509_cert.issuer, attribute)
    end

    def find_subject_attribute(attribute)
      find_name_attribute(x509_cert.subject, attribute)
    end

  end

end