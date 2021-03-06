require "bindeps/version"
require "unpacker"
require "fixwhich"
require "tmpdir"
require "yaml"
require "fileutils"

module Bindeps

  class DownloadFailedError < StandardError; end
  class UnsupportedSystemError < StandardError; end

  def self.require dependencies
    if dependencies.is_a? String
      dependencies = YAML.load_file dependencies
    end
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir) do
        dependencies.each_pair do |name, config|
          unpack = config.key?('unpack') ? config['unpack'] : true;
          libraries = config.key?('libraries') ? config['libraries'] : []
          d = Dependency.new(name,
                             config['binaries'],
                             config['version'],
                             config['url'],
                             unpack,
                             libraries)
          d.install_missing
        end
      end
    end
  end

  # Check whether all dependencies are installed. Return an array of missing
  # dependencies.
  def self.missing dependencies
    if dependencies.is_a? String
      dependencies = YAML.load_file dependencies
    end
    missing = []
    Dir.mktmpdir do |tmpdir|
      Dir.chdir(tmpdir) do
        dependencies.each_pair do |name, config|
          unpack = config.key?('unpack') ? config['unpack'] : true;
          libraries = config.key?('libraries') ? config['libraries'] : []
          d = Dependency.new(name,
                             config['binaries'],
                             config['version'],
                             config['url'],
                             unpack,
                             libraries)
          missing << d unless d.all_installed?
        end
      end
    end
    missing
  end

  class Dependency

    attr_reader :name, :version, :binaries, :libraries

    include Which

    def initialize(name, binaries, versionconfig, urlconfig,
                   unpack, libraries=[])
      @name = name
      unless binaries.is_a? Array
        raise ArgumentError,
              "binaries must be an array"
      end
      @binaries = binaries
      @libraries = libraries
      @version = versionconfig['number']
      @version_cmd = versionconfig['command']
      @url = choose_url urlconfig
      @unpack = unpack
    end

    def install_missing
      unless all_installed?
        puts "Installing #{@name} (#{@version})..."
        download
        unpack
      end
    end

    def choose_url urlconfig
      arch = System.arch
      if urlconfig.key? arch
        sys = urlconfig[arch]
        os = System.os.to_s
        if sys.key? os
          return sys[os]
        else
          raise UnsupportedSystemError,
                "bindeps config for #{@name} #{arch} doesn't " +
                "contain an entry for #{os}"
        end
      else
        raise UnsupportedSystemError,
              "bindeps config for #{@name} doesn't contain an " +
              "entry for #{arch}"
      end
    end

    def download
      wget = which('wget').first
      curl = which('curl').first
      if wget
        cmd = "#{wget} #{@url}"
        stdout, stderr, status = Open3.capture3 cmd
      elsif curl
        cmd = "#{curl} -O -J -L #{@url}"
        stdout, stderr, status = Open3.capture3 cmd
      else
        msg = "You don't have curl or wget?! What kind of computer is "
        msg << "this?! Windows?! BeOS? OS/2?"
        raise DownloadFailedError.new(msg)
      end
      if !status.success?
        raise DownloadFailedError,
              "download of #{@url} for #{@name} failed:\n#{stdout}\n#{stderr}"
      end
    end

    def unpack
      archive = File.basename(@url)
      Unpacker.archive? archive
      if @unpack
        Unpacker.unpack(archive) do |dir|
          Dir.chdir dir do
            Dir['**/*'].each do |extracted|
              file = File.basename(extracted)
              if @binaries.include?(file) || @libraries.include?(file)
                dir = File.dirname extracted
                dir = %w[bin lib].include?(dir) ? dir : '.'
                install(extracted, dir) unless File.directory?(extracted)
              end
            end
          end
        end
      else
        install(@binaries.first, 'bin')
      end
    end

    def all_installed?
      @binaries.each do |bin|
        unless installed? bin
          return false
        end
      end
      true
    end

    def installed? bin
      path = which(bin)
      if path.length > 0
        ret = `#{@version_cmd} 2>&1`.split("\n").map{ |l| l.strip }.join('|')
        if ret && (/#{@version}/ =~ ret)
          return path
        end
      else
        if Dir.exist?("#{ENV['HOME']}/.local/bin")
          ENV['PATH'] = ENV['PATH'] + ":#{ENV['HOME']}/.local/bin"
          path = which(bin)
          if path.length > 0
            return path
          end
        end
      end
      false
    end

    def install(src, destprefix)
      gem_home = ENV['GEM_HOME']
      home = ENV['HOME']
      basedir = File.join(home, '.local')
      if gem_home.nil?
        ENV['PATH'] = ENV['PATH'] + ":#{File.join(basedir, 'bin')}"
      else
        basedir = ENV['GEM_HOME']
      end
      FileUtils.mkdir_p File.join(basedir, 'bin')
      FileUtils.mkdir_p File.join(basedir, 'lib')
      destprefix = 'bin' if destprefix == '.'
      install_location = File.join(basedir, destprefix, File.basename(src))
      FileUtils.install(src, install_location, :mode => 0775)
    end

  end

  class System

    require 'rbconfig'

    def self.os
      (
        host_os = RbConfig::CONFIG['host_os']
        case host_os
        when /mswin|msys|mingw|cygwin|bccwin|wince|emc/
          :windows
        when /darwin|mac os/
          :macosx
        when /linux/
          :linux
        when /solaris|bsd/
          :unix
        else
          raise UnsupportedSystemError,
                "can't install #{@name}, unknown os: #{host_os.inspect}"
        end
      )
    end

    def self.arch
      Gem::Platform.local.cpu == 'x86_64' ? '64bit' : '32bit'
    end

  end

end
